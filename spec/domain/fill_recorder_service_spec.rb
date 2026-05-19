require "rails_helper"

RSpec.describe Domain::FillRecorderService do
  let(:logger) { instance_double(Logger, warn: nil) }
  let(:service) { described_class.new(logger: logger) }

  let(:definition) do
    Strategy::Definition.create!(name: "FRS Strat", market_type: "futures", status: "active")
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
      name: "FRS Policy",
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

  def build_trade(status:, **attrs)
    LiveTrading::Trade.create!(
      {
        live_trading_session: session, strategy_revision: revision,
        symbol: "BTCUSDT", side: "long", quantity: BigDecimal("1.0"), status: status
      }.merge(attrs)
    )
  end

  def build_order(trade:, trade_side:, size:, bitget_order_id:, status: "placed")
    Exchange::Order.create!(
      live_trading_trade: trade, strategy_revision: revision,
      symbol: "BTCUSDT", side: "long", trade_side: trade_side,
      order_type: "market", size: size, status: status,
      force: "gtc", bitget_order_id: bitget_order_id
    )
  end

  def fill_push(order_id:, trade_id:, price:, base_volume:, fee: "0.5", fee_coin: "USDT", c_time: "1700000000000")
    {
      "orderId" => order_id, "tradeId" => trade_id, "price" => price,
      "baseVolume" => base_volume,
      "feeDetail" => [ { "feeCoin" => fee_coin, "totalFee" => fee } ],
      "cTime" => c_time
    }
  end

  describe "#record_fill_from_push" do
    subject { service.record_fill_from_push(push_row, session: session) }

    context "エントリー fill で Order が全約定した場合" do
      let!(:trade) { build_trade(status: "entering") }
      let!(:order) { build_order(trade: trade, trade_side: "open", size: BigDecimal("1.0"), bitget_order_id: "bg-entry-1") }
      let(:push_row) do
        fill_push(order_id: "bg-entry-1", trade_id: "fill-1", price: "50000", base_volume: "1.0")
      end

      it "Exchange::Fill を作成し Trade を open へ遷移する" do
        expect { subject }.to change(Exchange::Fill, :count).by(1)

        fill = Exchange::Fill.last
        expect(fill.exchange_order).to eq(order)
        expect(fill.price).to eq(BigDecimal("50000"))
        expect(fill.size).to eq(BigDecimal("1.0"))
        expect(fill.fee).to eq(BigDecimal("0.5"))
        expect(fill.fee_coin).to eq("USDT")

        trade.reload
        expect(trade).to be_state_open
        expect(trade.entry_price).to eq(BigDecimal("50000"))
        expect(trade.entry_at).to be_present
      end
    end

    context "エントリー fill が部分約定の場合" do
      let!(:trade) { build_trade(status: "entering") }
      let!(:order) { build_order(trade: trade, trade_side: "open", size: BigDecimal("1.0"), bitget_order_id: "bg-entry-2") }
      let(:push_row) do
        fill_push(order_id: "bg-entry-2", trade_id: "fill-2", price: "50000", base_volume: "0.4")
      end

      it "Exchange::Fill は作成するが Trade は entering のまま集計しない" do
        expect { subject }.to change(Exchange::Fill, :count).by(1)
        expect(trade.reload).to be_state_entering
      end
    end

    context "部分約定後の追加 fill でエントリー Order が全約定した場合" do
      let!(:trade) { build_trade(status: "entering") }
      let!(:order) { build_order(trade: trade, trade_side: "open", size: BigDecimal("1.0"), bitget_order_id: "bg-entry-3") }
      let(:push_row) do
        fill_push(order_id: "bg-entry-3", trade_id: "fill-3b", price: "50200", base_volume: "0.4")
      end

      before do
        service.record_fill_from_push(
          fill_push(order_id: "bg-entry-3", trade_id: "fill-3a", price: "50000", base_volume: "0.6"),
          session: session
        )
      end

      it "加重平均 entry_price で Trade を open へ遷移する" do
        subject
        trade.reload
        expect(trade).to be_state_open
        # (50000 * 0.6 + 50200 * 0.4) / 1.0 = 50080
        expect(trade.entry_price).to eq(BigDecimal("50080"))
      end
    end

    context "決済 fill で決済 Order が全約定した場合" do
      let!(:trade) do
        build_trade(status: "closing", entry_price: BigDecimal("50000"), entry_at: Time.current)
      end
      let!(:entry_order) do
        o = build_order(trade: trade, trade_side: "open", size: BigDecimal("1.0"),
                        bitget_order_id: "bg-entry-4", status: "filled")
        Exchange::Fill.create!(
          exchange_order: o, bitget_fill_id: "fill-entry-4",
          price: BigDecimal("50000"), size: BigDecimal("1.0"),
          fee: BigDecimal("25"), fee_coin: "USDT", filled_at: Time.current
        )
        o
      end
      let!(:close_order) do
        build_order(trade: trade, trade_side: "close", size: BigDecimal("1.0"), bitget_order_id: "bg-close-4")
      end
      let(:push_row) do
        fill_push(order_id: "bg-close-4", trade_id: "fill-close-4", price: "51000", base_volume: "1.0", fee: "25.5")
      end

      it "決済 Fill を作成し Trade を closed へ realized_pnl 付きで遷移する" do
        subject
        trade.reload
        expect(trade).to be_state_closed
        expect(trade.exit_price).to eq(BigDecimal("51000"))
        # (51000 - 50000) * 1.0 - (25 + 25.5) = 949.5
        expect(trade.realized_pnl).to eq(BigDecimal("949.5"))
      end
    end

    context "親 Order が見つからない場合" do
      let(:push_row) do
        fill_push(order_id: "unknown-order", trade_id: "fill-x", price: "50000", base_volume: "1.0")
      end

      it "Exchange::Fill を作成せず logger.warn で skip する" do
        expect { subject }.not_to change(Exchange::Fill, :count)
        expect(logger).to have_received(:warn).with(/parent order not found/)
      end
    end

    context "同一 tradeId の fill push が再到達した場合" do
      let!(:trade) { build_trade(status: "entering") }
      let!(:order) { build_order(trade: trade, trade_side: "open", size: BigDecimal("2.0"), bitget_order_id: "bg-entry-5") }
      let(:push_row) do
        fill_push(order_id: "bg-entry-5", trade_id: "fill-dup", price: "50000", base_volume: "1.0")
      end

      before { service.record_fill_from_push(push_row, session: session) }

      it "Exchange::Fill を二重作成しない(bitget_fill_id 冪等)" do
        expect { subject }.not_to change(Exchange::Fill, :count)
      end
    end

    context "全約定済(open)の Trade に追加 fill push が届いた場合" do
      let!(:trade) { build_trade(status: "open", entry_price: BigDecimal("50000"), entry_at: Time.current) }
      let!(:order) { build_order(trade: trade, trade_side: "open", size: BigDecimal("1.0"), bitget_order_id: "bg-entry-6") }
      let(:push_row) do
        fill_push(order_id: "bg-entry-6", trade_id: "fill-6", price: "50000", base_volume: "1.0")
      end

      it "Trade を再遷移せず open のまま例外も出ない" do
        expect { subject }.not_to raise_error
        expect(trade.reload).to be_state_open
      end
    end
  end
end
