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

    private_constant :SUPPORTED_MODES

    # @param order_endpoint [Infrastructure::BitgetOrderEndpoint] 全注文 cancel + close_positions
    # @param position_endpoint [Infrastructure::BitgetPositionEndpoint] reduce_only 追従ループでの position 取得(Step 3)
    # @param clock [#call] reduce_only 追従ループの elapsed 判定(Step 3)
    # @param logger [Logger] 部分失敗 warn / 致命エラー error 出力先
    def initialize(order_endpoint:, position_endpoint:, clock: -> { Time.current }, logger: Rails.logger)
      @order_endpoint = order_endpoint
      @position_endpoint = position_endpoint
      @clock = clock
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
        # Step 3 で実装予定
        raise NotImplementedError, "cancel_and_reduce_only is planned for Phase 3.4a Step 3"
      end
    end

    private

    attr_reader :order_endpoint, :position_endpoint, :clock, :logger

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
