require "rails_helper"

RSpec.describe "Dashboard(View)", type: :request do
  let!(:definition) { Strategy::Definition.create!(name: "Dash UI", market_type: "futures", status: "active") }
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
      name: "Dash UI Policy", max_drawdown_pct: BigDecimal("20"),
      consecutive_loss_limit: 5, max_position_exposure_usdt: BigDecimal("1000"),
      max_leverage: 10, cooldown_minutes: 30, daily_loss_limit_usdt: BigDecimal("500")
    )
  end

  describe "GET /dashboard" do
    subject { get "/dashboard" }

    it "200 OK + KPI セクション + chart canvas を表示する" do
      subject
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("ダッシュボード")
      expect(response.body).to include("累積 PnL")
      expect(response.body).to include("稼働率")
      expect(response.body).to include("戦略別成績")
    end

    # 中-4 反映: total フィールドの表示なし
    it "累積 PnL に「合計」表示がない(中-4 反映)" do
      subject
      expect(response.body).not_to include("累積 PnL 合計")
    end
  end
end
