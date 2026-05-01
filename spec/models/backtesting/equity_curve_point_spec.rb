require "rails_helper"

RSpec.describe Backtesting::EquityCurvePoint, type: :model do
  let(:definition) do
    Strategy::Definition.create!(name: "EQ Strat", market_type: "futures", status: "active")
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
      status: "approved",
      ast_validation_status: "passed",
      uses_live_forbidden_input: false,
      ai_filter_enabled: false,
      ai_sizing_enabled: false
    )
  end
  let(:risk_policy) do
    Risk::Policy.create!(
      name: "EQ Policy",
      max_drawdown_pct: BigDecimal("20"),
      consecutive_loss_limit: 5,
      max_position_exposure_usdt: BigDecimal("1000"),
      max_leverage: 10,
      cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end
  let(:run) do
    Backtesting::Run.create!(
      strategy_definition: definition,
      strategy_revision: revision,
      risk_policy: risk_policy,
      symbol: "BTCUSDT",
      granularity: "1H",
      period_from: Time.utc(2026, 1, 1),
      period_to: Time.utc(2026, 1, 31),
      fee_rate: BigDecimal("0.001"),
      slippage_rate: BigDecimal("0.0005"),
      status: "completed"
    )
  end
  let(:base_attributes) do
    {
      run: run,
      ts: Time.utc(2026, 1, 5, 12, 0, 0),
      equity: BigDecimal("10500"),
      drawdown: BigDecimal("0.05"),
      position_size: BigDecimal("0.5")
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

    %i[ts equity position_size].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { base_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end

    context "drawdown が nil の場合" do
      let(:attributes) { base_attributes.merge(drawdown: nil) }

      it "valid? が true を返す(drawdown は nullable)" do
        expect(subject).to be_valid
      end
    end
  end

  describe "associations" do
    context "belongs_to :run の場合" do
      subject { described_class.reflect_on_association(:run) }

      it "Backtesting::Run を class_name に持ち backtesting_run_id を foreign_key に持つ" do
        expect(subject.macro).to eq(:belongs_to)
        expect(subject.options[:class_name]).to eq("Backtesting::Run")
        expect(subject.options[:foreign_key]).to eq(:backtesting_run_id)
      end
    end
  end
end
