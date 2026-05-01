require "rails_helper"

RSpec.describe Backtesting::Metrics, type: :model do
  let(:definition) do
    Strategy::Definition.create!(name: "M Strat", market_type: "futures", status: "active")
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
      name: "M Policy",
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
      win_rate: BigDecimal("0.55"),
      total_pnl: BigDecimal("123.45"),
      max_drawdown: BigDecimal("0.12"),
      sharpe_ratio: BigDecimal("1.5"),
      sortino_ratio: BigDecimal("2.1"),
      volatility: BigDecimal("0.08"),
      profit_factor: BigDecimal("1.8"),
      total_trades: 42,
      avg_holding_seconds: 3_600
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

    %i[win_rate total_pnl max_drawdown sharpe_ratio sortino_ratio volatility profit_factor total_trades avg_holding_seconds].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { base_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end

    context "win_rate が 0 未満の場合" do
      let(:attributes) { base_attributes.merge(win_rate: BigDecimal("-0.01")) }

      it "valid? が false を返し win_rate にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:win_rate]).to be_present
      end
    end

    context "win_rate が 1 を超える場合" do
      let(:attributes) { base_attributes.merge(win_rate: BigDecimal("1.01")) }

      it "valid? が false を返し win_rate にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:win_rate]).to be_present
      end
    end

    context "max_drawdown が負の場合" do
      let(:attributes) { base_attributes.merge(max_drawdown: BigDecimal("-0.1")) }

      it "valid? が false を返し max_drawdown にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:max_drawdown]).to be_present
      end
    end

    context "volatility が負の場合" do
      let(:attributes) { base_attributes.merge(volatility: BigDecimal("-0.01")) }

      it "valid? が false を返し volatility にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:volatility]).to be_present
      end
    end

    context "profit_factor が負の場合" do
      let(:attributes) { base_attributes.merge(profit_factor: BigDecimal("-1.0")) }

      it "valid? が false を返し profit_factor にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:profit_factor]).to be_present
      end
    end

    context "total_trades が負の場合" do
      let(:attributes) { base_attributes.merge(total_trades: -1) }

      it "valid? が false を返し total_trades にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:total_trades]).to be_present
      end
    end

    context "avg_holding_seconds が負の場合" do
      let(:attributes) { base_attributes.merge(avg_holding_seconds: -1) }

      it "valid? が false を返し avg_holding_seconds にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:avg_holding_seconds]).to be_present
      end
    end

    context "同一 backtesting_run_id で重複作成する場合" do
      before { described_class.create!(base_attributes) }

      let(:attributes) { base_attributes }

      it "uniqueness 違反で valid? が false を返す" do
        expect(subject).not_to be_valid
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
        expect(subject.options[:inverse_of]).to eq(:metrics)
      end
    end
  end
end
