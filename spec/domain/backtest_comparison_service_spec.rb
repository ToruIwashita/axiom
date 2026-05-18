require "rails_helper"

RSpec.describe Domain::BacktestComparisonService do
  let(:definition) { Strategy::Definition.create!(name: "Cmp Strat", market_type: "futures", status: "active") }
  let(:revision) do
    Strategy::Revision.create!(
      strategy_definition: definition, revision_number: 1,
      script_content: "class S < Domain::TradingScriptBase; def on_tick(ctx, candle); end; end",
      script_entrypoint: "S", status: "promoted", ast_validation_status: "passed",
      uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false,
      approved_at: Time.current, promoted_at: Time.current
    )
  end
  let(:risk_policy) do
    Risk::Policy.create!(
      name: "Cmp Policy", max_drawdown_pct: BigDecimal("20"),
      consecutive_loss_limit: 5, max_position_exposure_usdt: BigDecimal("1000"),
      max_leverage: 10, cooldown_minutes: 30, daily_loss_limit_usdt: BigDecimal("500")
    )
  end

  def create_run_with_metrics(total_pnl: BigDecimal("100"), period_from: 30.days.ago, period_to: 1.day.ago)
    run = Backtesting::Run.create!(
      strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy,
      symbol: "BTCUSDT", granularity: "1m",
      period_from: period_from, period_to: period_to,
      fee_rate: BigDecimal("0.0006"), slippage_rate: BigDecimal("0.0001"),
      status: "completed", finished_at: 1.hour.ago
    )
    Backtesting::Metrics.create!(
      run: run,
      win_rate: BigDecimal("0.5"), total_pnl: total_pnl,
      max_drawdown: BigDecimal("10"),
      sharpe_ratio: BigDecimal("1.0"), sortino_ratio: BigDecimal("1.5"),
      volatility: BigDecimal("0.1"), profit_factor: BigDecimal("1.2"),
      total_trades: 10, avg_holding_seconds: 300
    )
    run
  end

  def add_equity_points(run, count:)
    base_ts = run.period_from
    count.times do |i|
      Backtesting::EquityCurvePoint.create!(
        backtesting_run_id: run.id,
        ts: base_ts + i.minutes,
        equity: BigDecimal("1000") + BigDecimal(i),
        drawdown: BigDecimal("0"),
        position_size: BigDecimal("1")
      )
    end
  end

  describe "#metrics_table" do
    let!(:run_a) { create_run_with_metrics(total_pnl: BigDecimal("100")) }
    let!(:run_b) { create_run_with_metrics(total_pnl: BigDecimal("200")) }

    subject { described_class.new(run_ids: [ run_a.id, run_b.id ]).metrics_table }

    it "9 項目の metrics を Run 別に返す" do
      expect(subject.size).to eq(2)
      first = subject.first
      expect(first[:run_id]).to eq(run_a.id)
      expect(first[:label]).to include("Run ##{run_a.id}")
      expect(first[:metrics].keys).to contain_exactly(
        "win_rate", "total_pnl", "max_drawdown", "sharpe_ratio",
        "sortino_ratio", "volatility", "profit_factor",
        "total_trades", "avg_holding_seconds"
      )
    end

    it "Metrics 未生成の Run でも nil で返す(集計画面落ちを防ぐ)" do
      run_no_metrics = Backtesting::Run.create!(
        strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy,
        symbol: "BTCUSDT", granularity: "1m",
        period_from: 30.days.ago, period_to: 1.day.ago,
        fee_rate: BigDecimal("0.0006"), slippage_rate: BigDecimal("0.0001"),
        status: "running"
      )
      result = described_class.new(run_ids: [ run_no_metrics.id ]).metrics_table
      expect(result.first[:metrics]).to be_nil
    end
  end

  # 中-3 反映: 既存 BacktestingRunEquityCurveController#sampled_rows と同アルゴリズム適用
  describe "#equity_curves" do
    let!(:run_a) { create_run_with_metrics }
    let!(:run_b) { create_run_with_metrics }

    context "sample_size 以下の点数の場合" do
      before { add_equity_points(run_a, count: 5) }

      it "全点を返す" do
        result = described_class.new(run_ids: [ run_a.id ]).equity_curves(sample_size: 100)
        expect(result.first[:points].size).to eq(5)
      end
    end

    context "sample_size を超える点数の場合" do
      before { add_equity_points(run_a, count: 100) }

      it "every_n 間引きで sample_size 以下に絞る" do
        result = described_class.new(run_ids: [ run_a.id ]).equity_curves(sample_size: 10)
        # every_n = (100 / 10).ceil = 10 → 0, 10, 20, ..., 90 の 10 点
        expect(result.first[:points].size).to be <= 10
      end
    end

    it "各 Run について label + points を返す(複数 Run 重ね描き対応)" do
      add_equity_points(run_a, count: 3)
      add_equity_points(run_b, count: 3)
      result = described_class.new(run_ids: [ run_a.id, run_b.id ]).equity_curves
      expect(result.size).to eq(2)
      expect(result.first[:label]).to include("Run ##{run_a.id}")
      expect(result.first[:points].first.keys).to contain_exactly(:ts, :equity, :drawdown)
    end
  end

  describe "#parameter_diff" do
    let!(:run_a) { create_run_with_metrics(period_from: 30.days.ago) }
    let!(:run_b) { create_run_with_metrics(period_from: 60.days.ago) }

    subject { described_class.new(run_ids: [ run_a.id, run_b.id ]).parameter_diff }

    it "6 項目の parameter を Run 別に返す" do
      expect(subject.size).to eq(2)
      first = subject.first
      expect(first.keys).to include(
        :run_id, :period_from, :period_to, :fee_rate, :slippage_rate, :risk_policy_id, :strategy_revision_id
      )
    end
  end

  # 低-4 反映: logger DI
  describe "logger DI" do
    let!(:run) { create_run_with_metrics }

    it "constructor で logger を受け取れる" do
      logger = instance_double(Logger)
      expect { described_class.new(run_ids: [ run.id ], logger: logger) }.not_to raise_error
    end

    it "デフォルトは Rails.logger" do
      service = described_class.new(run_ids: [ run.id ])
      expect(service.send(:logger)).to eq(Rails.logger)
    end
  end
end
