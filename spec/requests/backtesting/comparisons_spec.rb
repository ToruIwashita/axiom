require "rails_helper"

RSpec.describe "Backtesting::Comparisons(View)", type: :request do
  let!(:definition) { Strategy::Definition.create!(name: "Cmp UI", market_type: "futures", status: "active") }
  let!(:revision) do
    Strategy::Revision.create!(
      strategy_definition: definition, revision_number: 1,
      script_content: "class S < Domain::TradingScriptBase; def on_tick(ctx, candle); end; end",
      script_entrypoint: "S", status: "promoted", ast_validation_status: "passed",
      uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false,
      approved_at: Time.current, promoted_at: Time.current
    )
  end
  let!(:risk_policy) do
    Risk::Policy.create!(
      name: "Cmp UI Policy", max_drawdown_pct: BigDecimal("20"),
      consecutive_loss_limit: 5, max_position_exposure_usdt: BigDecimal("1000"),
      max_leverage: 10, cooldown_minutes: 30, daily_loss_limit_usdt: BigDecimal("500")
    )
  end

  def create_completed_run(total_pnl: BigDecimal("100"))
    run = Backtesting::Run.create!(
      strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy,
      symbol: "BTCUSDT", granularity: "1m",
      period_from: 30.days.ago, period_to: 1.day.ago,
      fee_rate: BigDecimal("0.0006"), slippage_rate: BigDecimal("0.0001"),
      status: "completed", finished_at: 1.hour.ago
    )
    Backtesting::Metrics.create!(
      run: run, win_rate: BigDecimal("0.5"), total_pnl: total_pnl,
      max_drawdown: BigDecimal("10"),
      sharpe_ratio: BigDecimal("1.0"), sortino_ratio: BigDecimal("1.5"),
      volatility: BigDecimal("0.1"), profit_factor: BigDecimal("1.2"),
      total_trades: 10, avg_holding_seconds: 300
    )
    run
  end

  describe "GET /backtesting/comparisons/new" do
    let!(:run_a) { create_completed_run }
    let!(:run_b) { create_completed_run }

    it "200 OK + 完了済 Run の一覧 + 比較ボタンを表示する" do
      get "/backtesting/comparisons/new"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("バックテスト比較")
      expect(response.body).to include("Run ##{run_a.id}")
      expect(response.body).to include("Run ##{run_b.id}")
    end
  end

  describe "GET /backtesting/comparisons/show" do
    let!(:run_a) { create_completed_run(total_pnl: BigDecimal("100")) }
    let!(:run_b) { create_completed_run(total_pnl: BigDecimal("200")) }

    it "200 OK + metrics 表 + chart canvas + parameter 表を表示する" do
      get "/backtesting/comparisons/show", params: { run_ids: [ run_a.id, run_b.id ] }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("metrics 横並べ")
      expect(response.body).to include("equity curve")
      expect(response.body).to include("パラメータ差分")
    end

    it "run_ids が空の場合 redirect + flash alert" do
      get "/backtesting/comparisons/show", params: { run_ids: [] }
      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_present
    end
  end
end
