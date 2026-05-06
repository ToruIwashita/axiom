require "rails_helper"

RSpec.describe Exchange::Fill, type: :model do
  let(:definition) do
    Strategy::Definition.create!(name: "Live Strat", market_type: "futures", status: "active")
  end
  let(:script_body) do
    <<~RUBY
      class Sample < Domain::TradingScriptBase
        def on_tick(ctx, candle); end
      end
    RUBY
  end
  let(:revision) do
    Strategy::Revision.create!(
      strategy_definition: definition,
      revision_number: 1,
      script_content: script_body,
      script_entrypoint: "Sample",
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
      name: "Default Policy",
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
  let(:trade) do
    LiveTrading::Trade.create!(
      live_trading_session: session,
      strategy_revision: revision,
      symbol: "BTCUSDT",
      side: "long",
      quantity: BigDecimal("0.01"),
      status: "pending"
    )
  end
  let(:order) do
    Exchange::Order.create!(
      live_trading_trade: trade,
      strategy_revision: revision,
      symbol: "BTCUSDT",
      side: "long",
      trade_side: "open",
      order_type: "limit",
      price: BigDecimal("50000"),
      size: BigDecimal("0.01"),
      status: "placed",
      reduce_only: false,
      force: "gtc"
    )
  end
  let(:base_attributes) do
    {
      exchange_order: order,
      bitget_fill_id: "fill-12345",
      price: BigDecimal("50000"),
      size: BigDecimal("0.01"),
      fee: BigDecimal("0.5"),
      fee_coin: "USDT",
      filled_at: Time.utc(2026, 5, 5, 12, 0, 0)
    }
  end

  describe "validations" do
    subject { described_class.new(attributes) }

    context "必須属性が全て揃っている場合" do
      let(:attributes) { base_attributes }

      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end

    %i[bitget_fill_id price size fee fee_coin filled_at].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { base_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end

    context "size が 0 以下の場合" do
      let(:attributes) { base_attributes.merge(size: BigDecimal("0")) }

      it "valid? が false を返す" do
        expect(subject).not_to be_valid
        expect(subject.errors[:size]).to be_present
      end
    end

    context "bitget_fill_id が既存と重複する場合" do
      before { described_class.create!(base_attributes) }

      let(:attributes) { base_attributes }

      it "valid? が false を返し bitget_fill_id にエラー" do
        expect(subject).not_to be_valid
        expect(subject.errors[:bitget_fill_id]).to be_present
      end
    end
  end

  describe "関連" do
    let(:fill) { described_class.create!(base_attributes) }

    it "exchange_order に belongs_to で繋がる" do
      expect(fill.exchange_order).to eq(order)
    end
  end
end
