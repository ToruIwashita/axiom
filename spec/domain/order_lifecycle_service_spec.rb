require "rails_helper"

RSpec.describe Domain::OrderLifecycleService do
  let(:service) { described_class.new }

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
end
