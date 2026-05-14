require "rails_helper"

RSpec.describe "Api::V1::Dashboard", type: :request do
  let!(:definition) { Strategy::Definition.create!(name: "Dash API", market_type: "futures", status: "active") }
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
      name: "Dash API Policy", max_drawdown_pct: BigDecimal("20"),
      consecutive_loss_limit: 5, max_position_exposure_usdt: BigDecimal("1000"),
      max_leverage: 10, cooldown_minutes: 30, daily_loss_limit_usdt: BigDecimal("500")
    )
  end

  describe "GET /api/v1/dashboard" do
    subject { get "/api/v1/dashboard", as: :json }

    it "200 OK + cumulative_pnl / uptime_seconds / per_strategy_summary を返す" do
      subject
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to include("cumulative_pnl", "uptime_seconds", "per_strategy_summary")
    end

    # 中-4 反映: cumulative_pnl は backtesting / live_trading のみ / total なし
    it "cumulative_pnl レスポンスに total フィールドが含まれない(中-4 反映)" do
      subject
      pnl = response.parsed_body["cumulative_pnl"]
      expect(pnl.keys).to contain_exactly("backtesting", "live_trading")
      expect(pnl).not_to have_key("total")
    end

    # 中-5 反映: uptime_seconds は uptime_seconds_total + period_seconds のみ
    it "uptime_seconds は uptime_seconds_total + period_seconds のみで status 別フィールドなし(中-5 反映)" do
      subject
      uptime = response.parsed_body["uptime_seconds"]
      expect(uptime.keys).to contain_exactly("uptime_seconds_total", "period_seconds")
    end
  end
end
