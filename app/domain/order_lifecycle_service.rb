module Domain
  # LiveTrading::Trade / Exchange::Order の生成・状態遷移を担う Domain サービス(設計書 02_§2.2 d).
  #
  # Bitget API I/O は持たず(order_endpoint 呼出は LiveTradingWorker が担う),
  # DB レコードのライフサイクルのみを扱う stateless サービス.
  # 各メソッドは内部で LiveTrading::Session.transaction を張り Trade + Order の整合を保つ.
  class OrderLifecycleService
    # 1 ポジ運用前提に反し open な Trade が複数検出された場合に送出する(設計書 02_§2.2 d-2).
    class MultipleOpenTradesError < StandardError; end

    # @param logger [Logger] 契約違反等の警告出力先
    def initialize(logger: Rails.logger)
      @logger = logger
    end

    # エントリー intent から Trade(entering)とエントリー Order(pending)を作成する.
    #
    # Trade を pending で作成 → start_entering! で entering に遷移し,
    # 同 Trade に紐づくエントリー Order を pending で作成する.
    # client_oid は決定論的 ID を Bitget place-order と Order レコードで一致させるため
    # 呼出側(worker)が生成して渡す.
    #
    # @param session [LiveTrading::Session] 対象セッション
    # @param revision [Strategy::Revision] 戦略リビジョン
    # @param intent [Hash] order_intent(side / size / order_type / limit_price / tp_pct / sl_pct)
    # @param client_oid [String] エントリー Order の冪等性キー
    # @return [Exchange::Order] 作成された pending なエントリー Order
    def record_entry_open(session:, revision:, intent:, client_oid:)
      LiveTrading::Session.transaction do
        trade = LiveTrading::Trade.create!(
          live_trading_session: session,
          strategy_revision: revision,
          symbol: session.symbol,
          side: intent["side"],
          quantity: intent["size"],
          status: "pending",
          tp_pct: intent["tp_pct"],
          sl_pct: intent["sl_pct"]
        )
        trade.start_entering!

        Exchange::Order.create!(
          live_trading_trade: trade,
          strategy_revision: revision,
          symbol: session.symbol,
          side: intent["side"],
          trade_side: "open",
          order_type: intent["order_type"],
          size: intent["size"],
          status: "pending",
          force: intent.fetch("force", "gtc"),
          client_oid: client_oid,
          price: intent["limit_price"]
        )
      end
    end

    # place-order 成功時にエントリー Order を placed に遷移する.
    #
    # @param order [Exchange::Order] record_entry_open が返した Order
    # @param bitget_order_id [String] Bitget が返した order_id
    # @param placed_at [Time] 発注時刻
    # @return [void]
    def record_entry_placed(order:, bitget_order_id:, placed_at:)
      LiveTrading::Session.transaction do
        order.mark_placed!(bitget_order_id: bitget_order_id, placed_at: placed_at)
      end
    end

    # place-order 失敗時にエントリー Order を rejected,親 Trade を failed に遷移する.
    #
    # @param order [Exchange::Order] record_entry_open が返した Order
    # @param reason [String] 失敗理由
    # @return [void]
    def record_entry_rejected(order:, reason:)
      LiveTrading::Session.transaction do
        order.mark_rejected!(finished_at: Time.current)
        order.live_trading_trade.mark_failed!(reason: reason)
      end
    end

    # 明示 close: 当該 session の open な Trade を特定し決済 Order(pending / trade_side: close)を
    # 作成して親 Trade を closing に遷移する(設計書 02_§2.2 d / c-2).
    #
    # 決済 Order の全属性は特定した open Trade から導出する(client_oid は close_positions が
    # 非対応のため Exchange::Order の ensure_client_oid で内部 UUID 自動生成).
    # MVP は 1 ポジ運用のため open Trade は 0 / 1 を想定し,2 件以上は契約違反として fail-fast する.
    #
    # @param session [LiveTrading::Session] 対象セッション
    # @return [Exchange::Order, nil] 作成した決済 Order / open Trade 不在なら nil
    # @raise [MultipleOpenTradesError] open Trade が 2 件以上検出された場合(1 ポジ運用前提違反)
    def record_close_open(session:)
      open_trades = LiveTrading::Trade.where(live_trading_session_id: session.id, status: "open").to_a
      return nil if open_trades.empty?

      if open_trades.size > 1
        logger.error(
          "[OrderLifecycleService] multiple open trades detected for session_id=#{session.id} " \
          "(count=#{open_trades.size}); 1 ポジ運用前提の契約違反 / fail-fast"
        )
        raise MultipleOpenTradesError,
              "multiple open trades for session_id=#{session.id} (count=#{open_trades.size})"
      end

      trade = open_trades.first
      LiveTrading::Session.transaction do
        order = Exchange::Order.create!(
          live_trading_trade: trade,
          strategy_revision: trade.strategy_revision,
          symbol: trade.symbol,
          side: trade.side,
          trade_side: "close",
          order_type: "market",
          size: trade.quantity,
          status: "pending",
          force: "gtc"
        )
        trade.start_closing!
        order
      end
    end

    private

    attr_reader :logger
  end
end
