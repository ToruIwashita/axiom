module Domain
  # LiveTrading::Trade / Exchange::Order の生成・状態遷移を担う Domain サービス(設計書 02_§2.2 d).
  #
  # Bitget API I/O は持たず(order_endpoint 呼出は LiveTradingWorker が担う),
  # DB レコードのライフサイクルのみを扱う stateless サービス.
  # 各メソッドは内部で LiveTrading::Session.transaction を張り Trade + Order の整合を保つ.
  class OrderLifecycleService
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
    # MVP は 1 ポジ運用のため open Trade は 0 / 1 を想定し,2 件以上は契約違反として
    # logger.error で明示し nil を返して当該 close intent を reject する(raise しない:
    # 例外を raise すると process_order_intent の rescue StandardError に握られ
    # subtask 5.0 で是正した warn 落とし問題が再発するため / valid_intent_side? と一貫).
    #
    # @param session [LiveTrading::Session] 対象セッション
    # @return [Exchange::Order, nil] 作成した決済 Order /
    #   open Trade 不在,または open Trade が 2 件以上(1 ポジ運用前提違反 / logger.error 済)なら nil
    def record_close_open(session:)
      trade = single_open_trade(session)
      return nil if trade.nil?

      LiveTrading::Session.transaction do
        order = build_close_order(trade)
        trade.start_closing!
        order
      end
    end

    # WS orders push の 1 row を Exchange::Order に突合し状態遷移する(設計書 02_§2.2 d-4).
    #
    # 突合は 3 段(bitget_order_id → client_oid → 明示 close の pending 決済 Order)で行い,
    # 発見時は status マッピングで状態遷移,未発見の closing order は決済 Order を遅延作成,
    # 未発見の entry order は skip + warn する.
    #
    # @param push_row [Hash] orders push の 1 row(orderId / clientOid / tradeSide / status)
    # @param session [LiveTrading::Session] 対象セッション
    # @return [void]
    def sync_order_from_push(push_row, session:)
      LiveTrading::Session.transaction do
        order = find_existing_order(push_row, session)
        if order
          apply_order_status(order, push_row)
        elsif push_row["tradeSide"] == "close"
          create_lazy_close_order(push_row, session)
        else
          logger.warn(
            "[OrderLifecycleService] orders push: entry order not found " \
            "(orderId=#{push_row["orderId"]} clientOid=#{push_row["clientOid"]}); skip"
          )
        end
      end
    end

    private

    attr_reader :logger

    # 当該 session の open な Trade を 1 件特定する.
    # 0 件は nil,複数は 1 ポジ運用前提の契約違反として logger.error + nil(record_close_open / branch b 共通).
    def single_open_trade(session)
      open_trades = LiveTrading::Trade.where(live_trading_session_id: session.id, status: "open").to_a
      return nil if open_trades.empty?

      if open_trades.size > 1
        logger.error(
          "[OrderLifecycleService] multiple open trades detected for session_id=#{session.id} " \
          "(count=#{open_trades.size}); 1 ポジ運用前提の契約違反 / reject"
        )
        return nil
      end
      open_trades.first
    end

    # 決済 Order(pending / trade_side: close)を当該 Trade から導出して作成する.
    def build_close_order(trade)
      Exchange::Order.create!(
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
    end

    # orders push の 3 段突合(設計書 02_§2.2 d-4).
    def find_existing_order(push_row, session)
      order_id = push_row["orderId"]
      client_oid = push_row["clientOid"]

      order = Exchange::Order.find_by(bitget_order_id: order_id) if order_id.present?
      order ||= Exchange::Order.find_by(client_oid: client_oid) if client_oid.present?
      return order if order
      return nil unless push_row["tradeSide"] == "close"

      find_pending_close_order(session)
    end

    # 突合 3 段目: 当該 session の open / closing な Trade に紐づく
    # 「pending かつ bitget_order_id 未設定の決済 Order」= record_close_open が先に作成した
    # 明示 close の決済 Order を特定する.複数該当は契約違反として logger.error + nil.
    def find_pending_close_order(session)
      trade_ids = LiveTrading::Trade
        .where(live_trading_session_id: session.id, status: %w[open closing])
        .pluck(:id)
      return nil if trade_ids.empty?

      candidates = Exchange::Order.where(
        live_trading_trade_id: trade_ids, trade_side: "close",
        status: "pending", bitget_order_id: nil
      ).to_a
      if candidates.size > 1
        logger.error(
          "[OrderLifecycleService] multiple pending close orders without bitget_order_id " \
          "for session_id=#{session.id} (count=#{candidates.size}); 契約違反 / skip"
        )
        return nil
      end
      candidates.first
    end

    # Bitget orders status に応じて Exchange::Order を状態遷移する(branch a).
    # 終端 / 目標 state 以上は skip(冪等).live 取りこぼし時は mark_placed! を補完する.
    def apply_order_status(order, push_row)
      case push_row["status"]
      when "live"
        ensure_placed(order, push_row)
      when "partially_filled"
        ensure_placed(order, push_row)
        order.mark_partially_filled! if order.state_placed?
      when "filled"
        ensure_placed(order, push_row)
        order.mark_filled!(finished_at: Time.current) if order.state_placed? || order.state_partially_filled?
      when "canceled" # Bitget: canceled(L1) / Exchange::Order: cancelled(L2)
        unless order.terminal?
          assign_bitget_order_id_if_missing(order, push_row)
          order.mark_cancelled!(finished_at: Time.current)
        end
      end
      # "init" / 未知の status は意味のある DB 遷移なしのため skip
    end

    # branch b 由来の決済 Order(client_oid が内部 UUID)が canceled 経路で bitget_order_id 未設定の
    # まま残ると,再 push 時に 3 段突合の全段から漏れて二重作成される.canceled 遷移前に
    # bitget_order_id を設定し,再 push を 1 段目突合(bitget_order_id)で追えるようにする.
    def assign_bitget_order_id_if_missing(order, push_row)
      return unless order.bitget_order_id.nil? && push_row["orderId"].present?

      order.update!(bitget_order_id: push_row["orderId"])
    end

    # Order が pending なら placed に遷移する(missed-push 補完 / placed_at は不明のため nil).
    def ensure_placed(order, push_row)
      return unless order.state_pending?

      order.mark_placed!(bitget_order_id: push_row["orderId"], placed_at: nil)
    end

    # branch b: DB 未登録の closing order(TP/SL トリガー由来)に対し決済 Order を遅延作成し,
    # 親 Trade を closing に遷移して push の status を適用する.
    def create_lazy_close_order(push_row, session)
      trade = single_open_trade(session)
      return if trade.nil?

      order = build_close_order(trade)
      trade.start_closing!
      apply_order_status(order, push_row)
    end
  end
end
