require "rails_helper"

RSpec.describe ApplicationServices::BacktestingRunService do
  let(:service) { described_class.new }
  let!(:definition) { Strategy::Definition.create!(name: "BR Strat", market_type: "futures", status: "active") }
  let(:script_body) do
    <<~RUBY
      class Sample < Domain::TradingScriptBase
        def on_tick(ctx, candle); end
      end
    RUBY
  end
  let!(:revision) do
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
  let!(:risk_policy) do
    Risk::Policy.create!(
      name: "BR Policy",
      max_drawdown_pct: BigDecimal("20"),
      consecutive_loss_limit: 5,
      max_position_exposure_usdt: BigDecimal("1000"),
      max_leverage: 10,
      cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end
  let(:enqueue_attrs) do
    {
      definition_id: definition.id,
      strategy_revision_id: revision.id,
      risk_policy_id: risk_policy.id,
      symbol: "BTCUSDT",
      granularity: "1H",
      period_from: Time.utc(2026, 1, 1),
      period_to: Time.utc(2026, 1, 31),
      fee_rate: BigDecimal("0.001"),
      slippage_rate: BigDecimal("0.0005")
    }
  end

  describe "#enqueue_backtest" do
    around { |example| ActiveJob::Base.queue_adapter = :test; example.run }

    subject { service.enqueue_backtest(**enqueue_attrs) }

    context "整合検証 + 受入条件すべて満たす場合" do
      it "Backtesting::Run.create!(status: pending) + BacktestExecutionJob enqueue が実行される" do
        expect { subject }.to change { Backtesting::Run.count }.by(1)
          .and have_enqueued_job(BacktestExecutionJob)
        expect(subject).to be_state_pending
        expect(subject.strategy_definition).to eq(definition)
        expect(subject.strategy_revision).to eq(revision)
        expect(subject.risk_policy).to eq(risk_policy)
      end

      it "重要 2 検証: enqueue された Job の引数が作成された Run の id である" do
        run = subject
        expect(BacktestExecutionJob).to have_been_enqueued.with(run.id)
      end
    end

    context "整合検証失敗(path.definition_id != revision.strategy_definition_id)の場合" do
      let(:other_definition) { Strategy::Definition.create!(name: "Other", market_type: "futures", status: "active") }
      let(:enqueue_attrs) { super().merge(definition_id: other_definition.id) }

      it "ArgumentError を raise し Run は作成されず Job も enqueue されない" do
        before_count = Backtesting::Run.count
        expect { subject }.to raise_error(ArgumentError, /strategy_definition_id mismatch/)
        expect(Backtesting::Run.count).to eq(before_count)
        expect(BacktestExecutionJob).not_to have_been_enqueued
      end
    end

    context "受入条件失敗(revision.status が draft の場合)" do
      let!(:revision) do
        Strategy::Revision.create!(
          strategy_definition: definition,
          revision_number: 1,
          script_content: script_body,
          script_entrypoint: "Sample",
          status: "draft",
          ast_validation_status: "passed",
          uses_live_forbidden_input: false,
          ai_filter_enabled: false,
          ai_sizing_enabled: false
        )
      end

      it "ArgumentError を raise する(acceptable_for_backtest? = false)" do
        expect { subject }.to raise_error(ArgumentError, /acceptable for backtest/)
      end
    end

    context "存在しない strategy_revision_id の場合(軽微追加 A)" do
      let(:enqueue_attrs) { super().merge(strategy_revision_id: 0) }

      it "ActiveRecord::RecordNotFound を raise する" do
        expect { subject }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "#cancel" do
    let!(:run) do
      Backtesting::Run.create!(
        strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy,
        symbol: "BTCUSDT", granularity: "1H",
        period_from: Time.utc(2026, 1, 1), period_to: Time.utc(2026, 1, 31),
        fee_rate: BigDecimal("0.001"), slippage_rate: BigDecimal("0.0005"),
        status: status
      )
    end

    subject { service.cancel(run_id: run.id) }

    %w[pending running].each do |s|
      context "#{s} 状態の Run を cancel する場合" do
        let(:status) { s }

        it "cancelled 状態に遷移する" do
          subject
          expect(run.reload).to be_state_cancelled
        end
      end
    end

    %w[completed failed cancelled].each do |s|
      context "#{s}(terminal)状態の Run を cancel する場合" do
        let(:status) { s }

        it "状態は変化せず元の Run を返す" do
          before_status = run.status
          result = subject
          expect(result.status).to eq(before_status)
        end
      end
    end
  end

  describe "#get" do
    let!(:run) do
      Backtesting::Run.create!(
        strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy,
        symbol: "BTCUSDT", granularity: "1H",
        period_from: Time.utc(2026, 1, 1), period_to: Time.utc(2026, 1, 31),
        fee_rate: BigDecimal("0.001"), slippage_rate: BigDecimal("0.0005"),
        status: "completed"
      )
    end

    context "存在する run_id を渡した場合" do
      subject { service.get(run_id: run.id) }

      it "Backtesting::Run を返す" do
        expect(subject).to eq(run)
      end
    end

    context "存在しない run_id を渡した場合" do
      subject { service.get(run_id: 0) }

      it "ActiveRecord::RecordNotFound を raise する" do
        expect { subject }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "#list" do
    let!(:run_pending) do
      Backtesting::Run.create!(
        strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy,
        symbol: "BTCUSDT", granularity: "1H",
        period_from: Time.utc(2026, 1, 1), period_to: Time.utc(2026, 1, 31),
        fee_rate: BigDecimal("0.001"), slippage_rate: BigDecimal("0.0005"),
        status: "pending", created_at: 2.days.ago
      )
    end
    let!(:run_completed) do
      Backtesting::Run.create!(
        strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy,
        symbol: "BTCUSDT", granularity: "1H",
        period_from: Time.utc(2026, 1, 1), period_to: Time.utc(2026, 1, 31),
        fee_rate: BigDecimal("0.001"), slippage_rate: BigDecimal("0.0005"),
        status: "completed", created_at: 1.day.ago
      )
    end

    context "filters なしの場合" do
      subject { service.list.to_a }

      it "created_at desc 順で全件返す" do
        expect(subject.first(2)).to eq([ run_completed, run_pending ])
      end
    end

    context "filters: { status: pending } の場合" do
      subject { service.list(filters: { status: "pending" }).to_a }

      it "pending のみ返す" do
        expect(subject).to eq([ run_pending ])
      end
    end

    context "filters: { strategy_definition_id: id } の場合" do
      subject { service.list(filters: { strategy_definition_id: definition.id }).to_a }

      it "該当 Definition の Run のみ返す" do
        expect(subject).to contain_exactly(run_pending, run_completed)
      end
    end
  end
end
