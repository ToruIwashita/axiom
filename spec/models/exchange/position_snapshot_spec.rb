require "rails_helper"

RSpec.describe Exchange::PositionSnapshot, type: :model do
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
  let(:base_attributes) do
    {
      live_trading_session: session,
      margin_coin: "USDT",
      symbol: "BTCUSDT",
      hold_side: "long",
      margin_size: BigDecimal("100"),
      leverage: 10,
      margin_mode: "isolated",
      pos_mode: "one_way_mode",
      asset_mode: "single",
      open_price_avg: BigDecimal("50000"),
      break_even_price: BigDecimal("50050"),
      mark_price: BigDecimal("50100"),
      total: BigDecimal("0.02"),
      available: BigDecimal("0.02"),
      frozen_size: BigDecimal("0"),
      unrealized_pl: BigDecimal("2"),
      unrealized_plr: BigDecimal("0.02"),
      liquidation_price: BigDecimal("45000"),
      keep_margin_rate: BigDecimal("0.005"),
      margin_rate: BigDecimal("0.05"),
      total_fee: BigDecimal("0.5"),
      deducted_fee: BigDecimal("0.0"),
      auto_margin: false,
      snapshot_at: Time.utc(2026, 5, 5, 12, 0, 0)
    }
  end

  describe "validations" do
    subject { described_class.new(attributes) }

    context "全 23 フィールドが揃っている場合" do
      let(:attributes) { base_attributes }

      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end

    %i[margin_coin symbol hold_side total snapshot_at].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { base_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end
  end

  describe ".latest_for scope" do
    let(:t1) { Time.utc(2026, 5, 5, 12, 0, 0) }
    let(:t2) { Time.utc(2026, 5, 5, 12, 5, 0) }
    let(:t3) { Time.utc(2026, 5, 5, 12, 10, 0) }

    let(:other_session) do
      LiveTrading::Session.create!(
        strategy_definition: definition,
        strategy_revision: revision,
        risk_policy: risk_policy,
        symbol: "ETHUSDT",
        leverage: 5,
        margin_mode: "crossed",
        position_mode: "one_way_mode",
        asset_mode: "single",
        margin_coin: "USDT",
        emergency_stop_mode: "cancel_only",
        status: "running"
      )
    end

    before do
      [ t1, t2, t3 ].each do |t|
        described_class.create!(base_attributes.merge(snapshot_at: t))
      end
      described_class.create!(base_attributes.merge(live_trading_session: other_session, snapshot_at: t3))
    end

    it "指定 session の最新 snapshot を 1 件返す" do
      result = described_class.latest_for(session.id)
      expect(result.count).to eq(1)
      expect(result.first.snapshot_at).to eq(t3)
      expect(result.first.live_trading_session_id).to eq(session.id)
    end
  end

  describe "関連" do
    let(:snapshot) { described_class.create!(base_attributes) }

    it "live_trading_session に belongs_to で繋がる" do
      expect(snapshot.live_trading_session).to eq(session)
    end
  end
end
