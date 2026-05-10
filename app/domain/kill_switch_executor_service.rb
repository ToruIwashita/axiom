require "bigdecimal"

module Domain
  # ユーザー指示の kill-switch(stop / emergency_stop)実行を担う Domain サービス.
  #
  # Phase 3.4a Step 1 で初版(cancel_only モード)を実装. 後続 Step 2 で cancel_and_market_close,
  # Step 3 で cancel_and_reduce_only を追加予定(02_§6.2.1 / 設計書 05_§5).
  #
  # 責務:
  #   - 3 モードの kill-switch 実行(現状: cancel_only のみ)
  #   - 全 pending order(通常 + plan)の取消し
  #   - 結果 Symbol(:stopped / :halted)を返却(Worker 側で session.update! する責務分担 / レビュー重要 3-(c) 反映)
  #
  # mode 一覧(設計書 05_§5):
  #   - :cancel_only: 全注文取消 + ポジション保持 → :stopped
  #   - :cancel_and_market_close: 全注文取消 + close_positions 即時成行 → :stopped / :halted (Step 2)
  #   - :cancel_and_reduce_only: 全注文取消 + reduce_only 指値追従ループ + fallback → :stopped / :halted (Step 3)
  #
  # 部分失敗時の方針:
  #   - 個別 order の cancel 失敗は logger.warn 落とし + 後続継続(MVP / kill-switch は best-effort)
  #   - orders_pending 取得自体の失敗(致命エラー)は :halted 返却 + logger.error
  class KillSwitchExecutorService
    SUPPORTED_MODES = %i[cancel_only cancel_and_market_close cancel_and_reduce_only].freeze

    DEFAULT_REDUCE_ONLY_PARAMS = {
      limit_offset_bps: 0,
      follow_interval_sec: 5,
      fallback_after_sec: 60,
      max_follow_iterations: 20
    }.freeze

    private_constant :SUPPORTED_MODES, :DEFAULT_REDUCE_ONLY_PARAMS

    # @param order_endpoint [Infrastructure::BitgetOrderEndpoint] 全注文 cancel + close_positions
    # @param position_endpoint [Infrastructure::BitgetPositionEndpoint] reduce_only 追従ループでの position 取得
    # @param clock [#call] reduce_only 追従ループの elapsed 判定(monotonic clock 推奨 / 壁時計逆行耐性)
    # @param sleep_proc [#call] reduce_only 追従ループの sleep 注入(spec で no-op 化用)
    # @param logger [Logger] 部分失敗 warn / 致命エラー error 出力先
    def initialize(order_endpoint:, position_endpoint:,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   sleep_proc: ->(sec) { sleep(sec) },
                   logger: Rails.logger)
      @order_endpoint = order_endpoint
      @position_endpoint = position_endpoint
      @clock = clock
      @sleep_proc = sleep_proc
      @logger = logger
    end

    # kill-switch 実行のエントリポイント.
    #
    # @param session [LiveTrading::Session]
    # @param mode [Symbol] :cancel_only / :cancel_and_market_close / :cancel_and_reduce_only
    # @param params [Hash] mode 固有パラメータ(Step 3 で使用予定)
    # @return [Symbol] :stopped / :halted
    # @raise [ArgumentError] mode が SUPPORTED_MODES に含まれない場合
    def execute(session:, mode:, params: {})
      raise ArgumentError, "unsupported mode: #{mode.inspect}" unless SUPPORTED_MODES.include?(mode)

      case mode
      when :cancel_only
        execute_cancel_only(session)
      when :cancel_and_market_close
        execute_cancel_and_market_close(session)
      when :cancel_and_reduce_only
        execute_cancel_and_reduce_only(session, params || {})
      end
    end

    private

    attr_reader :order_endpoint, :position_endpoint, :clock, :sleep_proc, :logger

    # cancel_only モード: 全 pending order(通常 + plan)を取消し,ポジションは保持.
    def execute_cancel_only(session)
      cancel_all_pending_normal_orders(session)
      cancel_all_pending_plan_orders(session)
      :stopped
    rescue StandardError => e
      logger.error(
        "[KillSwitchExecutorService] cancel_only failed: " \
        "#{e.class.name}: #{Domain::FailureReasonSanitizer.sanitize(e.message)}"
      )
      :halted
    end

    # cancel_and_market_close モード: 全 pending order 取消 + close_positions 即時成行.
    # one_way_mode: hold_side: nil で 1 回呼ぶ / hedge_mode: long + short の各 side を呼ぶ.
    # close_positions 失敗は致命エラーとして :halted 返却(ポジション残存の運用リスク回避).
    def execute_cancel_and_market_close(session)
      cancel_all_pending_normal_orders(session)
      cancel_all_pending_plan_orders(session)
      close_all_positions(session)
      :stopped
    rescue StandardError => e
      logger.error(
        "[KillSwitchExecutorService] cancel_and_market_close failed: " \
        "#{e.class.name}: #{Domain::FailureReasonSanitizer.sanitize(e.message)}"
      )
      :halted
    end

    def cancel_all_pending_normal_orders(session)
      response = order_endpoint.orders_pending(symbol: session.symbol)
      orders = extract_data_array(response)
      orders.each do |order|
        order_id = order.is_a?(Hash) ? order["orderId"] : nil
        next if order_id.nil?

        begin
          order_endpoint.cancel_order(symbol: session.symbol, order_id: order_id)
        rescue StandardError => e
          logger.warn(
            "[KillSwitchExecutorService] cancel_order failed (order_id=#{order_id}): " \
            "#{e.class.name}: #{Domain::FailureReasonSanitizer.sanitize(e.message)}"
          )
        end
      end
    end

    def cancel_all_pending_plan_orders(session)
      response = order_endpoint.orders_plan_pending(symbol: session.symbol)
      plans = extract_data_array(response)
      plans.each do |plan|
        order_id = plan.is_a?(Hash) ? plan["orderId"] : nil
        next if order_id.nil?

        begin
          order_endpoint.cancel_plan_order(symbol: session.symbol, order_id: order_id)
        rescue StandardError => e
          logger.warn(
            "[KillSwitchExecutorService] cancel_plan_order failed (order_id=#{order_id}): " \
            "#{e.class.name}: #{Domain::FailureReasonSanitizer.sanitize(e.message)}"
          )
        end
      end
    end

    # cancel_and_reduce_only モード: 全 pending order 取消 + reduce_only 指値追従ループ +
    # fallback close_positions 成行クローズ.
    #
    # レビュー重要 3 反映:
    # (a) fallback 直前に reduce_only 指値を必ずキャンセル(設計書原文)
    # (b) elapsed_sec の起点 started_at = clock.call を冒頭で明示
    # (c) 戻り値は :stopped / :halted Symbol(Worker 側で session.update! する責務分担)
    # (d) ループ条件は時刻ベース fallback と iterations 上限の両方適用(時刻優先 / iterations は安全網)
    def execute_cancel_and_reduce_only(session, params)
      cancel_all_pending_normal_orders(session)
      cancel_all_pending_plan_orders(session)
      run_reduce_only_follow_loop(session, DEFAULT_REDUCE_ONLY_PARAMS.merge(params))
    rescue StandardError => e
      logger.error(
        "[KillSwitchExecutorService] cancel_and_reduce_only failed: " \
        "#{e.class.name}: #{Domain::FailureReasonSanitizer.sanitize(e.message)}"
      )
      :halted
    end

    def run_reduce_only_follow_loop(session, config)
      started_at = clock.call # 重要 3-(b): elapsed 起点
      iterations = 0
      reduce_only_order_id = nil

      # 重要 3-(d): 時刻ベース fallback と iterations 上限の両方適用
      while (clock.call - started_at) < config[:fallback_after_sec] && iterations < config[:max_follow_iterations]
        position = fetch_active_position(session)
        return :stopped if position.nil?

        desired_price = calculate_desired_price(position, config[:limit_offset_bps])
        reduce_only_order_id = place_or_modify_reduce_only(
          session, position, desired_price, reduce_only_order_id
        )

        sleep_proc.call(config[:follow_interval_sec])
        iterations += 1
      end

      # ループ終了後の最終確認: position が消えていれば :stopped
      position = fetch_active_position(session)
      return :stopped if position.nil?

      # 重要 3-(a): fallback 直前に reduce_only 指値を必ずキャンセル
      cancel_reduce_only_order_if_exists(session, reduce_only_order_id)
      execute_fallback_close(session, position)
    end

    def fetch_active_position(session)
      response = position_endpoint.position_all(margin_coin: session.margin_coin, symbol: session.symbol)
      positions = extract_data_array(response)
        .select { |p| p.is_a?(Hash) && p["symbol"] == session.symbol }
      positions.find { |p| BigDecimal(p["total"].to_s).positive? }
    end

    def calculate_desired_price(position, limit_offset_bps)
      mark_price = BigDecimal(position["markPrice"].to_s)
      offset_factor = BigDecimal(limit_offset_bps.to_s) / BigDecimal("10000")
      # close long → 売却 → mark_price * (1 + offset)(passive 寄り)
      # close short → 買戻 → mark_price * (1 - offset)
      offset_factor = -offset_factor if position["holdSide"] == "short"
      mark_price * (BigDecimal("1") + offset_factor)
    end

    def place_or_modify_reduce_only(session, position, desired_price, existing_order_id)
      if existing_order_id
        begin
          order_endpoint.modify_order(
            symbol: session.symbol,
            order_id: existing_order_id,
            new_price: desired_price
          )
          return existing_order_id
        rescue StandardError => e
          logger.warn(
            "[KillSwitchExecutorService] modify_order failed (order_id=#{existing_order_id}): " \
            "#{e.class.name}: #{Domain::FailureReasonSanitizer.sanitize(e.message)}"
          )
        end
      end

      response = order_endpoint.place_order(build_reduce_only_params(session, position, desired_price))
      data = response.is_a?(Hash) ? response["data"] : nil
      data.is_a?(Hash) ? data["orderId"] : nil
    end

    def build_reduce_only_params(session, position, desired_price)
      hold_side = position["holdSide"]
      params = {
        symbol: session.symbol,
        margin_mode: session.margin_mode,
        margin_coin: session.margin_coin,
        side: opposite_side(hold_side),
        order_type: "limit",
        size: position["total"],
        price: desired_price,
        force: "gtc",
        reduce_only: "yes",
        client_oid: "reduce_only_close-#{session.id}-#{clock.call.to_i}"
      }
      params[:trade_side] = "close" if session.position_mode == "hedge_mode"
      params
    end

    def opposite_side(hold_side)
      hold_side == "short" ? "buy" : "sell"
    end

    def cancel_reduce_only_order_if_exists(session, order_id)
      return if order_id.nil?

      begin
        order_endpoint.cancel_order(symbol: session.symbol, order_id: order_id)
      rescue StandardError => e
        logger.warn(
          "[KillSwitchExecutorService] cancel_order (reduce_only fallback) failed: " \
          "#{e.class.name}: #{Domain::FailureReasonSanitizer.sanitize(e.message)}"
        )
      end
    end

    def execute_fallback_close(session, position)
      hold_side = session.position_mode == "hedge_mode" ? position["holdSide"] : nil
      order_endpoint.close_positions(symbol: session.symbol, hold_side: hold_side)
      :stopped
    rescue StandardError => e
      logger.error(
        "[KillSwitchExecutorService] cancel_and_reduce_only fallback close_positions failed: " \
        "#{e.class.name}: #{Domain::FailureReasonSanitizer.sanitize(e.message)}"
      )
      :halted
    end

    # 全 position を close_positions 即時成行で解除する.
    # session.position_mode で one_way / hedge を判別:
    # - one_way_mode: 該当 symbol で total > 0 の position が 1 件でもあれば 1 回 close_positions(hold_side: nil)
    # - hedge_mode: total > 0 の各 holdSide ごとに close_positions(hold_side: side)
    def close_all_positions(session)
      response = position_endpoint.position_all(margin_coin: session.margin_coin, symbol: session.symbol)
      positions = extract_data_array(response)
        .select { |p| p.is_a?(Hash) && p["symbol"] == session.symbol }
      active = positions.select { |p| BigDecimal(p["total"].to_s).positive? }
      return if active.empty?

      if session.position_mode == "hedge_mode"
        active.each do |position|
          order_endpoint.close_positions(symbol: session.symbol, hold_side: position["holdSide"])
        end
      else
        # one_way_mode(または unset): hold_side: nil で 1 回呼出
        order_endpoint.close_positions(symbol: session.symbol, hold_side: nil)
      end
    end

    # Bitget API レスポンス形式 `{"data": [...]}` から Array を取り出す.
    # 異常形式(nil / 非 Array)の場合は空配列で安全に no-op 化.
    def extract_data_array(response)
      return [] unless response.is_a?(Hash)

      data = response["data"]
      data.is_a?(Array) ? data : []
    end
  end
end
