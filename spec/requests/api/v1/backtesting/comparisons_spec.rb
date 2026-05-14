require "rails_helper"

RSpec.describe "Api::V1::Backtesting::Comparisons", type: :request do
  let!(:definition) { Strategy::Definition.create!(name: "Cmp API", market_type: "futures", status: "active") }
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
      name: "Cmp API Policy", max_drawdown_pct: BigDecimal("20"),
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
      run: run,
      win_rate: BigDecimal("0.5"), total_pnl: total_pnl,
      max_drawdown: BigDecimal("10"),
      sharpe_ratio: BigDecimal("1.0"), sortino_ratio: BigDecimal("1.5"),
      volatility: BigDecimal("0.1"), profit_factor: BigDecimal("1.2"),
      total_trades: 10, avg_holding_seconds: 300
    )
    run
  end

  describe "GET /api/v1/backtesting/comparisons/show" do
    let!(:run_a) { create_completed_run(total_pnl: BigDecimal("100")) }
    let!(:run_b) { create_completed_run(total_pnl: BigDecimal("200")) }

    subject { get "/api/v1/backtesting/comparisons/show", params: { run_ids: [ run_a.id, run_b.id ] }, as: :json }

    it "200 OK + metrics_table / equity_curves / parameter_diff を返す" do
      subject
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to include("metrics_table", "equity_curves", "parameter_diff")
      expect(body["metrics_table"].size).to eq(2)
    end

    it "run_ids が空の場合 400 Bad Request" do
      get "/api/v1/backtesting/comparisons/show", params: { run_ids: [] }, as: :json
      expect(response).to have_http_status(:bad_request)
    end
  end
end
