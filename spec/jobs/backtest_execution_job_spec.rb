require "rails_helper"

RSpec.describe BacktestExecutionJob do
  let!(:definition) { Strategy::Definition.create!(name: "Job Strat", market_type: "futures", status: "active") }
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
      name: "Job Policy",
      max_drawdown_pct: BigDecimal("20"),
      consecutive_loss_limit: 5,
      max_position_exposure_usdt: BigDecimal("1000"),
      max_leverage: 10,
      cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end
  let(:run_attrs) do
    {
      strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy,
      symbol: "BTCUSDT", granularity: "1H",
      period_from: Time.utc(2026, 1, 1), period_to: Time.utc(2026, 1, 31),
      fee_rate: BigDecimal("0.001"), slippage_rate: BigDecimal("0.0005"),
      status: "pending"
    }
  end
  let!(:run) { Backtesting::Run.create!(run_attrs) }

  let(:repository) { instance_double(Infrastructure::MarketDataRepository) }
  let(:engine) { instance_double(Domain::BacktestEngineService) }
  let(:dummy_metrics) do
    Domain::PnLMetricsValueObject.new(
      win_rate: BigDecimal("0.5"), total_pnl: BigDecimal("100"), max_drawdown: BigDecimal("0.1"),
      sharpe_ratio: BigDecimal("1.0"), sortino_ratio: BigDecimal("1.5"), volatility: BigDecimal("0.2"),
      profit_factor: BigDecimal("1.5"), total_trades: 5, avg_holding_seconds: 3_600
    )
  end
  let(:dummy_trade) do
    {
      side: "long",
      entry_at: Time.utc(2026, 1, 5), exit_at: Time.utc(2026, 1, 5, 1),
      entry_price: BigDecimal("40000"), exit_price: BigDecimal("41000"),
      quantity: BigDecimal("0.5"), pnl: BigDecimal("500")
    }
  end
  let(:dummy_curve_point) do
    { ts: Time.utc(2026, 1, 5), equity: BigDecimal("10100"), drawdown: BigDecimal("0"), position_size: BigDecimal("0") }
  end
  let(:engine_result) do
    { trades: [ dummy_trade ], metrics: dummy_metrics, equity_curve: [ dummy_curve_point ] }
  end

  before do
    allow(Infrastructure::MarketDataRepository).to receive(:new).and_return(repository)
    allow(Domain::BacktestEngineService).to receive(:new).and_return(engine)
    fake_relation = double("Relation")
    allow(fake_relation).to receive(:pluck).and_return([])
    allow(repository).to receive(:fetch_futures_candles).and_return(fake_relation)
    allow(repository).to receive(:fetch_funding_rates).and_return(fake_relation)
    allow(repository).to receive(:fetch_mark_candles).and_return(fake_relation)
    allow(repository).to receive(:fetch_spot_candles).and_return(fake_relation)
  end

  describe "#perform" do
    subject { described_class.new.perform(run.id) }

    context "正常終了する場合" do
      before { allow(engine).to receive(:run).and_return(engine_result) }

      it "running → completed に遷移し Trade / Metrics / EquityCurvePoint を保存する" do
        expect { subject }.to change { Backtesting::Trade.count }.by(1)
          .and change { Backtesting::Metrics.count }.by(1)
          .and change { Backtesting::EquityCurvePoint.count }.by(1)
        expect(run.reload).to be_state_completed
        expect(run.started_at).to be_present
        expect(run.finished_at).to be_present
      end
    end

    context "BacktestEngineService が例外を投げた場合(Obs-C: 再 raise 省略)" do
      before { allow(engine).to receive(:run).and_raise(StandardError, "boom") }

      it "raise せず failed に遷移し failure_reason に例外内容が記録される" do
        expect { subject }.not_to raise_error
        expect(run.reload).to be_state_failed
        expect(run.failure_reason).to include("StandardError: boom")
        expect(run.finished_at).to be_present
      end
    end

    context "failure_reason が 10_000 文字を超える場合(Obs-D: truncate)" do
      before do
        long_msg = "x" * 12_000
        allow(engine).to receive(:run).and_raise(StandardError, long_msg)
      end

      it "failure_reason が 10_000 文字以内に truncate される" do
        subject
        expect(run.reload.failure_reason.length).to be <= 10_000
      end
    end

    context "重要 5: rescue 内で run が既に terminal(cancelled)になっている場合" do
      before do
        allow(engine).to receive(:run) do
          # engine.run 実行中に別経路で cancelled に遷移したと仮定
          run.update!(status: "cancelled")
          raise StandardError, "boom"
        end
      end

      it "二次例外を発生させず Job が落ちない(reload.terminal? チェックで fail! スキップ)" do
        expect { subject }.not_to raise_error
        expect(run.reload).to be_state_cancelled
      end
    end

    context "二重起動防止: status が pending 以外の場合" do
      let!(:run) { Backtesting::Run.create!(run_attrs.merge(status: "running")) }

      it "何もせず即 return する(start! は呼ばれず engine も実行されない)" do
        expect(engine).not_to receive(:run)
        subject
        expect(run.reload).to be_state_running
      end
    end
  end

  describe "sidekiq_options retry: false" do
    subject { described_class.sidekiq_options_hash }

    it "retry が false に設定されている(設計書 05_§7.3)" do
      expect(subject["retry"]).to be false
    end
  end

  describe "軽微 1: persist_result transaction(Phase 2.2 完了レビュー)" do
    subject { described_class.new.perform(run.id) }

    let(:invalid_metrics) do
      # win_rate を範囲外(2.0 = >1)で生成し Backtesting::Metrics validation 違反を誘発
      Domain::PnLMetricsValueObject.new(
        win_rate: BigDecimal("2.0"), total_pnl: BigDecimal("100"), max_drawdown: BigDecimal("0.1"),
        sharpe_ratio: BigDecimal("1.0"), sortino_ratio: BigDecimal("1.5"), volatility: BigDecimal("0.2"),
        profit_factor: BigDecimal("1.5"), total_trades: 5, avg_holding_seconds: 3_600
      )
    end
    let(:engine_result_with_invalid_metrics) do
      { trades: [ dummy_trade ], metrics: invalid_metrics, equity_curve: [ dummy_curve_point ] }
    end

    context "Metrics.create! が validation 違反で失敗する場合" do
      before { allow(engine).to receive(:run).and_return(engine_result_with_invalid_metrics) }

      it "Trade も EquityCurvePoint もロールバックされる(部分書込なし)" do
        before_trade_count = Backtesting::Trade.count
        before_metrics_count = Backtesting::Metrics.count
        before_curve_count = Backtesting::EquityCurvePoint.count
        subject
        expect(Backtesting::Trade.count).to eq(before_trade_count)
        expect(Backtesting::Metrics.count).to eq(before_metrics_count)
        expect(Backtesting::EquityCurvePoint.count).to eq(before_curve_count)
        expect(run.reload).to be_state_failed
        expect(run.failure_reason).to be_present
      end
    end
  end
end
