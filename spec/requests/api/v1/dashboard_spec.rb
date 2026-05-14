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

    # multi-agent review followup(spec coverage 高-3):
    # BigDecimal の JSON 精度欠落回避のため Controller で .to_s 化されている事を保証
    context "BigDecimal フィールドが String 化される(精度欠落回避)" do
      let!(:risk_policy_for_data) { risk_policy }
      let!(:session) do
        LiveTrading::Session.create!(
          strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy_for_data,
          symbol: "BTCUSDT", leverage: 10, margin_mode: "isolated",
          position_mode: "one_way_mode", asset_mode: "single", margin_coin: "USDT",
          emergency_stop_mode: "cancel_only", status: "running", started_at: 1.hour.ago
        )
      end
      before do
        LiveTrading::Trade.create!(
          live_trading_session_id: session.id, strategy_revision_id: revision.id,
          symbol: "BTCUSDT", side: "long", quantity: BigDecimal("1"),
          status: "closed",
          entry_price: BigDecimal("100"), entry_at: 1.hour.ago,
          exit_price: BigDecimal("110"), exit_at: 30.minutes.ago,
          realized_pnl: BigDecimal("10")
        )
      end

      it "cumulative_pnl の値は String 型 / per_strategy_summary の live_pnl も String 型" do
        subject
        body = response.parsed_body
        expect(body["cumulative_pnl"]["backtesting"]).to be_a(String)
        expect(body["cumulative_pnl"]["live_trading"]).to be_a(String)
        summary = body["per_strategy_summary"].find { |s| s["revision_id"] == revision.id }
        expect(summary["live_pnl"]).to be_a(String)
      end
    end
  end
end
