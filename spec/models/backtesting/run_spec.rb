require "rails_helper"

RSpec.describe Backtesting::Run, type: :model do
  let(:definition) do
    Strategy::Definition.create!(name: "Backtest Strat", market_type: "futures", status: "active")
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
      name: "Default Policy",
      max_drawdown_pct: BigDecimal("20"),
      consecutive_loss_limit: 5,
      max_position_exposure_usdt: BigDecimal("1000"),
      max_leverage: 10,
      cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end
  let(:base_attributes) do
    {
      strategy_definition: definition,
      strategy_revision: revision,
      risk_policy: risk_policy,
      symbol: "BTCUSDT",
      granularity: "1H",
      period_from: Time.utc(2026, 1, 1, 0, 0, 0),
      period_to: Time.utc(2026, 1, 31, 23, 59, 59),
      fee_rate: BigDecimal("0.001"),
      slippage_rate: BigDecimal("0.0005"),
      include_funding_rate: false,
      use_mark_basis: false,
      use_spot_basis: false,
      status: "pending"
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

    %i[symbol granularity period_from period_to fee_rate slippage_rate status].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { base_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end

    context "fee_rate が負の場合" do
      let(:attributes) { base_attributes.merge(fee_rate: BigDecimal("-0.001")) }

      it "valid? が false を返し fee_rate にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:fee_rate]).to be_present
      end
    end

    context "slippage_rate が負の場合" do
      let(:attributes) { base_attributes.merge(slippage_rate: BigDecimal("-0.0005")) }

      it "valid? が false を返し slippage_rate にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:slippage_rate]).to be_present
      end
    end

    context "period_to が period_from と同時刻の場合" do
      let(:attributes) { base_attributes.merge(period_to: base_attributes[:period_from]) }

      it "valid? が false を返し period_to にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:period_to]).to be_present
      end
    end

    context "period_to が period_from より前の場合" do
      let(:attributes) { base_attributes.merge(period_to: base_attributes[:period_from] - 1.day) }

      it "valid? が false を返し period_to にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:period_to]).to be_present
      end
    end
  end

  describe "status enum (prefix: :state)" do
    subject { described_class.create!(base_attributes.merge(status: status)) }

    %w[pending running completed failed cancelled].each do |state|
      context "#{state} 状態で作成した場合" do
        let(:status) { state }

        it "state_#{state}? が true を返す" do
          expect(subject.public_send("state_#{state}?")).to be true
        end
      end
    end
  end

  describe "associations" do
    context "belongs_to :strategy_definition の場合" do
      subject { described_class.reflect_on_association(:strategy_definition) }

      it "Strategy::Definition を class_name に持つ belongs_to" do
        expect(subject.macro).to eq(:belongs_to)
        expect(subject.options[:class_name]).to eq("Strategy::Definition")
      end
    end

    context "belongs_to :strategy_revision の場合" do
      subject { described_class.reflect_on_association(:strategy_revision) }

      it "Strategy::Revision を class_name に持つ belongs_to" do
        expect(subject.macro).to eq(:belongs_to)
        expect(subject.options[:class_name]).to eq("Strategy::Revision")
      end
    end

    context "belongs_to :risk_policy の場合" do
      subject { described_class.reflect_on_association(:risk_policy) }

      it "Risk::Policy を class_name に持つ belongs_to" do
        expect(subject.macro).to eq(:belongs_to)
        expect(subject.options[:class_name]).to eq("Risk::Policy")
      end
    end

    context "has_one :metrics の場合" do
      subject { described_class.reflect_on_association(:metrics) }

      it "Backtesting::Metrics を class_name に持ち backtesting_run_id を foreign_key に持つ" do
        expect(subject.macro).to eq(:has_one)
        expect(subject.options[:class_name]).to eq("Backtesting::Metrics")
        expect(subject.options[:foreign_key]).to eq(:backtesting_run_id)
        expect(subject.options[:dependent]).to eq(:destroy)
      end
    end

    context "has_many :trades の場合" do
      subject { described_class.reflect_on_association(:trades) }

      it "Backtesting::Trade を class_name に持ち backtesting_run_id を foreign_key に持つ" do
        expect(subject.macro).to eq(:has_many)
        expect(subject.options[:class_name]).to eq("Backtesting::Trade")
        expect(subject.options[:foreign_key]).to eq(:backtesting_run_id)
        expect(subject.options[:dependent]).to eq(:destroy)
      end
    end

    context "has_many :equity_curve_points の場合" do
      subject { described_class.reflect_on_association(:equity_curve_points) }

      it "Backtesting::EquityCurvePoint を class_name に持ち backtesting_run_id を foreign_key に持つ" do
        expect(subject.macro).to eq(:has_many)
        expect(subject.options[:class_name]).to eq("Backtesting::EquityCurvePoint")
        expect(subject.options[:foreign_key]).to eq(:backtesting_run_id)
        expect(subject.options[:dependent]).to eq(:destroy)
      end
    end
  end

  describe "#start!" do
    let(:run) { described_class.create!(base_attributes.merge(status: status)) }
    let(:started_at) { Time.utc(2026, 4, 30, 0, 0, 0) }

    subject { run.start!(started_at: started_at) }

    context "pending 状態の Run に start! を呼ぶ場合" do
      let(:status) { "pending" }

      it "state_running? が true で started_at が設定される" do
        subject
        run.reload
        expect(run).to be_state_running
        expect(run.started_at).to eq(started_at)
      end
    end

    %w[running completed failed cancelled].each do |state|
      context "#{state} 状態の Run に start! を呼ぶ場合" do
        let(:status) { state }

        it "InvalidTransitionError を raise する" do
          expect { subject }.to raise_error(Backtesting::Run::InvalidTransitionError)
        end
      end
    end
  end

  describe "#complete!" do
    let(:run) { described_class.create!(base_attributes.merge(status: status)) }
    let(:finished_at) { Time.utc(2026, 4, 30, 1, 0, 0) }

    subject { run.complete!(finished_at: finished_at) }

    context "running 状態の Run に complete! を呼ぶ場合" do
      let(:status) { "running" }

      it "state_completed? が true で finished_at が設定される" do
        subject
        run.reload
        expect(run).to be_state_completed
        expect(run.finished_at).to eq(finished_at)
      end
    end

    %w[pending completed failed cancelled].each do |state|
      context "#{state} 状態の Run に complete! を呼ぶ場合" do
        let(:status) { state }

        it "InvalidTransitionError を raise する" do
          expect { subject }.to raise_error(Backtesting::Run::InvalidTransitionError)
        end
      end
    end
  end

  describe "#fail!" do
    let(:run) { described_class.create!(base_attributes.merge(status: status)) }
    let(:finished_at) { Time.utc(2026, 4, 30, 2, 0, 0) }
    let(:failure_reason) { "StandardError: boom" }

    subject { run.fail!(failure_reason: failure_reason, finished_at: finished_at) }

    %w[pending running].each do |state|
      context "#{state} 状態の Run に fail! を呼ぶ場合" do
        let(:status) { state }

        it "state_failed? が true で failure_reason / finished_at が設定される" do
          subject
          run.reload
          expect(run).to be_state_failed
          expect(run.failure_reason).to eq(failure_reason)
          expect(run.finished_at).to eq(finished_at)
        end
      end
    end

    %w[completed failed cancelled].each do |state|
      context "#{state} 状態の Run に fail! を呼ぶ場合" do
        let(:status) { state }

        it "InvalidTransitionError を raise する" do
          expect { subject }.to raise_error(Backtesting::Run::InvalidTransitionError)
        end
      end
    end

    context "failure_reason が 10_000 文字を超える場合(Obs-D)" do
      let(:status) { "running" }
      let(:long_reason) { "x" * 12_000 }

      subject { run.fail!(failure_reason: long_reason, finished_at: finished_at) }

      it "failure_reason が 10_000 文字に truncate される" do
        subject
        run.reload
        expect(run.failure_reason.length).to eq(10_000)
      end
    end
  end

  describe "#cancel!" do
    let(:run) { described_class.create!(base_attributes.merge(status: status)) }

    subject { run.cancel! }

    %w[pending running].each do |state|
      context "#{state} 状態の Run に cancel! を呼ぶ場合" do
        let(:status) { state }

        it "state_cancelled? が true を返す" do
          subject
          run.reload
          expect(run).to be_state_cancelled
        end
      end
    end

    %w[completed failed cancelled].each do |state|
      context "#{state} 状態の Run に cancel! を呼ぶ場合" do
        let(:status) { state }

        it "InvalidTransitionError を raise する" do
          expect { subject }.to raise_error(Backtesting::Run::InvalidTransitionError)
        end
      end
    end
  end

  describe "#terminal?" do
    subject { described_class.create!(base_attributes.merge(status: status)).terminal? }

    %w[completed failed cancelled].each do |state|
      context "#{state} 状態の場合" do
        let(:status) { state }

        it "true を返す" do
          expect(subject).to be true
        end
      end
    end

    %w[pending running].each do |state|
      context "#{state} 状態の場合" do
        let(:status) { state }

        it "false を返す" do
          expect(subject).to be false
        end
      end
    end
  end
end
