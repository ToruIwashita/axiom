require "bigdecimal"
require "securerandom"

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

    # 設計書 05_§5.1.1.1 line 892-895 準拠:
    # - limit_offset_bps: 10(0.1% passive 寄せ / mark_price ± 10bps で約定確率と slippage バランス)
    # - follow_interval_sec: 30(modify 頻度設計書整合 / Bitget rate limit 抵触リスク回避)
    # - fallback_after_sec: 300(5 分 / market 流動性低下時の slippage 抑制 / 約定機会確保)
    # - max_follow_iterations: 10(設計書 line 895「fallback_after_sec / follow_interval_sec から算出」式整合)
    DEFAULT_REDUCE_ONLY_PARAMS = {
      limit_offset_bps: 10,
      follow_interval_sec: 30,
      fallback_after_sec: 300,
      max_follow_iterations: 10
    }.freeze

    private_constant :SUPPORTED_MODES, :DEFAULT_REDUCE_ONLY_PARAMS

    # @param order_endpoint [Infrastructure::BitgetOrderEndpoint] 全注文 cancel + close_positions
    # @param position_endpoint [Infrastructure::BitgetPositionEndpoint] reduce_only 追従ループでの position 取得
    # @param monotonic_clock [#call] reduce_only 追従ループの elapsed 判定(壁時計逆行耐性 / 他 Domain と命名統一)
    # @param sleep_proc [#call] reduce_only 追従ループの sleep 注入(spec で no-op 化用)
    # @param logger [Logger] 部分失敗 warn / 致命エラー error 出力先
    def initialize(order_endpoint:, position_endpoint:,
                   monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   sleep_proc: ->(sec) { sleep(sec) },
                   logger: Rails.logger)
      @order_endpoint = order_endpoint
      @position_endpoint = position_endpoint
      @monotonic_clock = monotonic_clock
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

    attr_reader :order_endpoint, :position_endpoint, :monotonic_clock, :sleep_proc, :logger

    # cancel_only モード: 全 pending order(通常 + plan)を取消し,ポジションは保持.
    # cancel_all_pending_*_orders は内部の orders_pending / orders_plan_pending 取得失敗時に
    # それぞれ :halted-or-stopped の判定が必要なため 2 段階で評価する.
    def execute_cancel_only(session)
      normal_ok = cancel_all_pending_normal_orders(session)
      plan_ok = cancel_all_pending_plan_orders(session)
      normal_ok && plan_ok ? :stopped : :halted
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
      response = fetch_or_log(:orders_pending) do
        order_endpoint.orders_pending(symbol: session.symbol)
      end
      return false if response.nil?

      extract_data_array(response).each do |order|
        order_id = order.is_a?(Hash) ? order["orderId"] : nil
        next if order_id.nil?

        cancel_individual_order(:cancel_order, session: session, order_id: order_id)
      end
      true
    end

    # Bitget V2 で orders-plan-pending は planType ごとに分かれているため,
    # kill-switch では全 planType を iterate して cancel する.
    # 1 つでも fetch 失敗があれば false 返却(致命扱い).
    def cancel_all_pending_plan_orders(session)
      all_succeeded = true
      Infrastructure::BitgetOrderEndpoint::PLAN_TYPES.each do |plan_type|
        response = fetch_or_log(:orders_plan_pending, plan_type: plan_type) do
          order_endpoint.orders_plan_pending(plan_type: plan_type, symbol: session.symbol)
        end
        if response.nil?
          all_succeeded = false
          next
        end

        extract_data_array(response).each do |plan|
          order_id = plan.is_a?(Hash) ? plan["orderId"] : nil
          next if order_id.nil?

          cancel_individual_order(:cancel_plan_order, session: session, order_id: order_id)
        end
      end
      all_succeeded
    end

    # API 取得自体の失敗(致命)を logger.error + nil 返却で表現する共通 helper.
    # 追加コンテキスト(planType 等)があれば context 引数で渡す.
    def fetch_or_log(label, **context)
      yield
    rescue StandardError => e
      ctx_str = context.empty? ? "" : " (#{context.map { |k, v| "#{k}=#{v}" }.join(', ')})"
      logger.error(
        "[KillSwitchExecutorService] #{label} fetch failed#{ctx_str}: " \
        "#{e.class.name}: #{Domain::FailureReasonSanitizer.sanitize(e.message)}"
      )
      nil
    end

    # 個別 cancel 失敗(部分失敗)を logger.warn 落とし + 後続継続させる共通 helper.
    def cancel_individual_order(method, session:, order_id:)
      order_endpoint.public_send(method, symbol: session.symbol, order_id: order_id)
    rescue StandardError => e
      logger.warn(
        "[KillSwitchExecutorService] #{method} failed (order_id=#{order_id}): " \
        "#{e.class.name}: #{Domain::FailureReasonSanitizer.sanitize(e.message)}"
      )
    end

    # cancel_and_reduce_only モード: 全 pending order 取消 + reduce_only 指値追従ループ +
    # fallback close_positions 成行クローズ.
    #
    # レビュー重要 3 反映:
    # (a) fallback 直前に reduce_only 指値を必ずキャンセル(設計書原文)
    # (b) elapsed_sec の起点 started_at = monotonic_clock.call を冒頭で明示
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
      started_at = monotonic_clock.call # 重要 3-(b): elapsed 起点
      iterations = 0
      reduce_only_order_id = nil

      # 重要 3-(d): 時刻ベース fallback と iterations 上限の両方適用
      while (monotonic_clock.call - started_at) < config[:fallback_after_sec] && iterations < config[:max_follow_iterations]
        position = fetch_active_position(session)
        if position.nil?
          # ループ途中の close 完了でも reduce_only 指値は約定で消費されたか
          # まだ pending 残存の可能性があるため必ず cancel(残存指値の反対方向約定リスク回避).
          cancel_reduce_only_order_if_exists(session, reduce_only_order_id)
          return :stopped
        end

        desired_price = calculate_desired_price(position, config[:limit_offset_bps])
        if desired_price.nil?
          # markPrice 異常: 追従 abort して fallback close に直行(kill 用途 fail-safe)
          logger.warn(
            "[KillSwitchExecutorService] markPrice missing/invalid; aborting follow loop and falling back to close_positions"
          )
          break
        end

        reduce_only_order_id = place_or_modify_reduce_only(
          session, position, desired_price, reduce_only_order_id
        )

        sleep_proc.call(config[:follow_interval_sec])
        iterations += 1
      end

      # ループ終了後の最終確認: position が消えていれば :stopped(残存 reduce_only も cancel)
      position = fetch_active_position(session)
      if position.nil?
        cancel_reduce_only_order_if_exists(session, reduce_only_order_id)
        return :stopped
      end

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

    # markPrice が nil / 不正値の場合は nil を返し,呼出側で reduce_only 追従を諦めて
    # fallback close へ遷移する(kill 用途の fail-safe / 異常時にループに張り付かない).
    def calculate_desired_price(position, limit_offset_bps)
      mark_price_str = position["markPrice"].to_s
      return nil if mark_price_str.empty?

      mark_price = BigDecimal(mark_price_str)
      offset_factor = BigDecimal(limit_offset_bps.to_s) / BigDecimal("10000")
      # close long → 売却 → mark_price * (1 + offset)(passive 寄り)
      # close short → 買戻 → mark_price * (1 - offset)
      offset_factor = -offset_factor if position["holdSide"] == "short"
      mark_price * (BigDecimal("1") + offset_factor)
    rescue ArgumentError
      nil
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
          # 二重発注リスク回避: modify が失敗 → exchange 側に旧 reduce_only 指値が残存しうるため,
          # 新規 place_order の前に必ず cancel して連続注文の重複約定を防ぐ.
          cancel_individual_order(:cancel_order, session: session, order_id: existing_order_id)
        end
      end

      response = order_endpoint.place_order(build_reduce_only_params(session, position, desired_price))
      data = response.is_a?(Hash) ? response["data"] : nil
      new_order_id = data.is_a?(Hash) ? data["orderId"] : nil
      if new_order_id.nil?
        logger.warn(
          "[KillSwitchExecutorService] place_order returned no orderId; reduce_only tracking lost"
        )
      end
      new_order_id
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
        # client_oid は session id + monotonic clock 整数秒 + ランダム hex で衝突回避.
        # follow_interval_sec < 1s 設定や modify 失敗 → 再 place の 1 秒以内連続発注時も
        # SecureRandom.hex(8) によって独立性を確保する.
        client_oid: "reduce_only_close-#{session.id}-#{monotonic_clock.call.to_i}-#{SecureRandom.hex(8)}"
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
    #
    # position_all 取得自体が失敗した場合は kill 用途の fail-safe として
    # close_positions(hold_side: nil) を盲目的に呼ぶ(close_positions は idempotent / over-close リスクなし).
    def close_all_positions(session)
      begin
        response = position_endpoint.position_all(margin_coin: session.margin_coin, symbol: session.symbol)
      rescue StandardError => e
        logger.warn(
          "[KillSwitchExecutorService] position_all failed; fail-safe close_positions(nil): " \
          "#{e.class.name}: #{Domain::FailureReasonSanitizer.sanitize(e.message)}"
        )
        order_endpoint.close_positions(symbol: session.symbol, hold_side: nil)
        return
      end

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
