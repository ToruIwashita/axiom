require "rails_helper"

RSpec.describe Domain::OrderLifecycleService do
  let(:logger) { instance_double(Logger, error: nil, warn: nil, info: nil) }
  let(:service) { described_class.new(logger: logger) }

  let(:definition) do
    Strategy::Definition.create!(name: "OLS Strat", market_type: "futures", status: "active")
  end
  let(:revision) do
    Strategy::Revision.create!(
      strategy_definition: definition,
      revision_number: 1,
      script_content: "class S < Domain::TradingScriptBase; def on_tick(ctx, candle); end; end",
      script_entrypoint: "S",
      status: "promoted",
      ast_validation_status: "passed",
      uses_live_forbidden_input: false,
      ai_filter_enabled: false,
      ai_sizing_enabled: false,
      approved_at: Time.current,
      promoted_at: Time.current
    )
  end
  let(:risk_policy) do
    Risk::Policy.create!(
      name: "OLS Policy",
      max_drawdown_pct: BigDecimal("20"),
      consecutive_loss_limit: 5,
      max_position_exposure_usdt: BigDecimal("1000"),
      max_leverage: 10,
      cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end
  let(:session) do
    LiveTrading::Session.create!(
      strategy_definition: definition,
      strategy_revision: revision,
      risk_policy: risk_policy,
      symbol: "BTCUSDT",
      leverage: 10,
      margin_mode: "isolated",
      position_mode: "one_way_mode",
      asset_mode: "single",
      margin_coin: "USDT",
      emergency_stop_mode: "cancel_only",
      status: "running"
    )
  end

  describe "#record_entry_open" do
    subject do
      service.record_entry_open(
        session: session, revision: revision, intent: intent, client_oid: client_oid
      )
    end

    let(:client_oid) { "live-#{session.id}-1700000000000-0" }

    context "market long エントリーで tp_pct / sl_pct 指定ありの場合" do
      let(:intent) do
        {
          "side" => "long", "size" => "0.01", "order_type" => "market",
          "tp_pct" => "0.02", "sl_pct" => "0.01"
        }
      end

      it "Trade(entering)とエントリー Order(pending)を作成し Order を返す" do
        order = subject

        expect(order).to be_a(Exchange::Order)
        expect(order).to be_state_pending
        expect(order).to be_side_long
        expect(order).to be_trade_side_open
        expect(order).to be_order_type_market
        expect(order).to be_force_gtc
        expect(order.symbol).to eq("BTCUSDT")
        expect(order.size).to eq(BigDecimal("0.01"))
        expect(order.client_oid).to eq(client_oid)
        expect(order.strategy_revision).to eq(revision)
        expect(order.bitget_order_id).to be_nil

        trade = order.live_trading_trade
        expect(trade).to be_state_entering
        expect(trade).to be_side_long
        expect(trade.symbol).to eq("BTCUSDT")
        expect(trade.quantity).to eq(BigDecimal("0.01"))
        expect(trade.tp_pct).to eq(BigDecimal("0.02"))
        expect(trade.sl_pct).to eq(BigDecimal("0.01"))
        expect(trade.live_trading_session).to eq(session)
        expect(trade.strategy_revision).to eq(revision)
      end
    end

    context "limit short エントリーで tp_pct / sl_pct 未指定の場合" do
      let(:intent) do
        {
          "side" => "short", "size" => "0.5", "order_type" => "limit", "limit_price" => "49000"
        }
      end

      it "limit 価格を持つ Order を作成し Trade の tp_pct / sl_pct は nil となる" do
        order = subject

        expect(order).to be_side_short
        expect(order).to be_order_type_limit
        expect(order.price).to eq(BigDecimal("49000"))
        expect(order.size).to eq(BigDecimal("0.5"))

        trade = order.live_trading_trade
        expect(trade).to be_side_short
        expect(trade.quantity).to eq(BigDecimal("0.5"))
        expect(trade.tp_pct).to be_nil
        expect(trade.sl_pct).to be_nil
      end
    end
  end

  describe "#record_entry_placed" do
    subject do
      service.record_entry_placed(order: order, bitget_order_id: "bitget-order-001", placed_at: placed_at)
    end

    let(:placed_at) { Time.utc(2026, 5, 19, 0, 0, 0) }
    let(:order) do
      service.record_entry_open(
        session: session, revision: revision,
        intent: { "side" => "long", "size" => "0.01", "order_type" => "market" },
        client_oid: "live-#{session.id}-1700000000000-0"
      )
    end

    context "pending なエントリー Order の場合" do
      it "Order を placed に遷移し bitget_order_id / placed_at を記録する" do
        subject

        order.reload
        expect(order).to be_state_placed
        expect(order.bitget_order_id).to eq("bitget-order-001")
        expect(order.placed_at).to eq(placed_at)
      end
    end
  end

  describe "#record_entry_rejected" do
    subject { service.record_entry_rejected(order: order, reason: "Bitget rejected: insufficient margin") }

    let(:order) do
      service.record_entry_open(
        session: session, revision: revision,
        intent: { "side" => "long", "size" => "0.01", "order_type" => "market" },
        client_oid: "live-#{session.id}-1700000000000-0"
      )
    end

    context "pending なエントリー Order の場合" do
      it "Order を rejected,親 Trade を failed に遷移し失敗理由を記録する" do
        subject

        order.reload
        expect(order).to be_state_rejected
        expect(order.finished_at).to be_present

        trade = order.live_trading_trade.reload
        expect(trade).to be_state_failed
        expect(trade.failure_reason).to eq("Bitget rejected: insufficient margin")
      end
    end
  end

  describe "#record_close_open" do
    subject { service.record_close_open(session: session) }

    def create_open_trade
      LiveTrading::Trade.create!(
        live_trading_session: session, strategy_revision: revision,
        symbol: "BTCUSDT", side: "long", quantity: BigDecimal("0.01"), status: "open"
      )
    end

    context "open な Trade が 1 件存在する場合" do
      let!(:open_trade) { create_open_trade }

      it "決済 Order(pending / trade_side: close)を作成し親 Trade を closing に遷移する" do
        order = subject

        expect(order).to be_a(Exchange::Order)
        expect(order).to be_state_pending
        expect(order).to be_trade_side_close
        expect(order).to be_order_type_market
        expect(order).to be_side_long
        expect(order).to be_force_gtc
        expect(order.symbol).to eq("BTCUSDT")
        expect(order.size).to eq(BigDecimal("0.01"))
        expect(order.client_oid).to be_present
        expect(order.live_trading_trade).to eq(open_trade)
        expect(order.strategy_revision).to eq(revision)

        expect(open_trade.reload).to be_state_closing
      end
    end

    context "open な Trade が存在しない場合" do
      it "Order を作成せず nil を返す" do
        expect { subject }.not_to change(Exchange::Order, :count)
        expect(subject).to be_nil
      end
    end

    context "open な Trade が複数存在する場合(1 ポジ運用前提の契約違反)" do
      before do
        create_open_trade
        create_open_trade
      end

      it "logger.error で契約違反を明示し Order を作成せず nil を返す" do
        expect { subject }.not_to change(Exchange::Order, :count)
        expect(subject).to be_nil
        expect(logger).to have_received(:error).with(/multiple open trades/)
      end
    end
  end

  describe "#sync_order_from_push" do
    subject { service.sync_order_from_push(push_row, session: session) }

    def entry_order(client_oid:)
      service.record_entry_open(
        session: session, revision: revision,
        intent: { "side" => "long", "size" => "0.01", "order_type" => "market" },
        client_oid: client_oid
      )
    end

    def create_open_trade
      LiveTrading::Trade.create!(
        live_trading_session: session, strategy_revision: revision,
        symbol: "BTCUSDT", side: "long", quantity: BigDecimal("0.01"), status: "open"
      )
    end

    context "pending なエントリー Order に client_oid 突合で status=live push が届いた場合" do
      let!(:order) { entry_order(client_oid: "live-#{session.id}-a-0") }
      let(:push_row) do
        { "orderId" => "bg-order-1", "clientOid" => order.client_oid,
          "tradeSide" => "open", "status" => "live" }
      end

      it "Order を placed に遷移し bitget_order_id を設定する" do
        subject
        order.reload
        expect(order).to be_state_placed
        expect(order.bitget_order_id).to eq("bg-order-1")
      end
    end

    context "placed な Order に bitget_order_id 突合で status=filled push が届いた場合" do
      let!(:order) do
        o = entry_order(client_oid: "live-#{session.id}-b-0")
        service.record_entry_placed(order: o, bitget_order_id: "bg-order-2", placed_at: Time.current)
        o
      end
      let(:push_row) { { "orderId" => "bg-order-2", "tradeSide" => "open", "status" => "filled" } }

      it "Order を filled に遷移する" do
        subject
        expect(order.reload).to be_state_filled
      end
    end

    context "pending な Order に status=filled push が届いた場合(live 取りこぼし / missed-push 補完)" do
      let!(:order) { entry_order(client_oid: "live-#{session.id}-c-0") }
      let(:push_row) do
        { "orderId" => "bg-order-3", "clientOid" => order.client_oid,
          "tradeSide" => "open", "status" => "filled" }
      end

      it "mark_placed! を補完してから filled に遷移する" do
        subject
        order.reload
        expect(order).to be_state_filled
        expect(order.bitget_order_id).to eq("bg-order-3")
      end
    end

    context "placed な Order に status=canceled push が届いた場合" do
      let!(:order) do
        o = entry_order(client_oid: "live-#{session.id}-d-0")
        service.record_entry_placed(order: o, bitget_order_id: "bg-order-4", placed_at: Time.current)
        o
      end
      let(:push_row) { { "orderId" => "bg-order-4", "tradeSide" => "open", "status" => "canceled" } }

      it "Order を cancelled に遷移する" do
        subject
        expect(order.reload).to be_state_cancelled
      end
    end

    context "status=init push の場合" do
      let!(:order) { entry_order(client_oid: "live-#{session.id}-e-0") }
      let(:push_row) do
        { "orderId" => "bg-order-5", "clientOid" => order.client_oid,
          "tradeSide" => "open", "status" => "init" }
      end

      it "状態遷移せず pending のままとなる" do
        subject
        expect(order.reload).to be_state_pending
      end
    end

    context "明示 close の決済 Order が突合 3 段目で発見される場合" do
      let!(:open_trade) { create_open_trade }
      let!(:close_order) { service.record_close_open(session: session) }
      let(:push_row) do
        { "orderId" => "bg-close-1", "clientOid" => "bitget-generated-oid",
          "tradeSide" => "close", "status" => "filled" }
      end

      it "pending な決済 Order を発見し bitget_order_id 設定 + filled へ遷移する" do
        subject
        close_order.reload
        expect(close_order).to be_state_filled
        expect(close_order.bitget_order_id).to eq("bg-close-1")
      end
    end

    context "DB 未登録の closing order push の場合(branch b / TP/SL トリガー由来)" do
      let!(:open_trade) { create_open_trade }
      let(:push_row) { { "orderId" => "bg-tpsl-1", "tradeSide" => "close", "status" => "filled" } }

      it "決済 Order を新規作成し親 Trade を closing に遷移する" do
        expect { subject }.to change(Exchange::Order, :count).by(1)

        new_order = Exchange::Order.find_by(bitget_order_id: "bg-tpsl-1")
        expect(new_order).to be_trade_side_close
        expect(new_order).to be_state_filled
        expect(new_order.live_trading_trade).to eq(open_trade)
        expect(open_trade.reload).to be_state_closing
      end
    end

    context "DB 未登録の entry order push の場合(branch c)" do
      let(:push_row) do
        { "orderId" => "unknown-1", "clientOid" => "unknown-coid",
          "tradeSide" => "open", "status" => "live" }
      end

      it "Order を作成せず logger.warn で skip する" do
        expect { subject }.not_to change(Exchange::Order, :count)
        expect(logger).to have_received(:warn).with(/entry order not found/)
      end
    end
  end
end
