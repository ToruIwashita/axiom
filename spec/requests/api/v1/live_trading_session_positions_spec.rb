require "rails_helper"

RSpec.describe "Api::V1::LiveTradingSessionPositions", type: :request do
  let!(:definition) { Strategy::Definition.create!(name: "LSP Strat", market_type: "futures", status: "active") }
  let(:script_body) do
    <<~RUBY
      class Sample < Domain::TradingScriptBase
        def on_tick(ctx, candle); end
      end
    RUBY
  end
  let!(:revision) do
    Strategy::Revision.create!(
      strategy_definition: definition, revision_number: 1, script_content: script_body,
      script_entrypoint: "Sample", status: "promoted", ast_validation_status: "passed",
      uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false,
      approved_at: Time.current, promoted_at: Time.current
    )
  end
  let!(:risk_policy) do
    Risk::Policy.create!(
      name: "LSP Policy", max_drawdown_pct: BigDecimal("20"), consecutive_loss_limit: 5,
      max_position_exposure_usdt: BigDecimal("1000"), max_leverage: 10, cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end
  let!(:session) do
    LiveTrading::Session.create!(
      strategy_definition: definition, strategy_revision: revision, risk_policy_id: risk_policy.id,
      symbol: "BTCUSDT", leverage: 10, margin_mode: "isolated", position_mode: "one_way_mode",
      asset_mode: "single", margin_coin: "USDT", emergency_stop_mode: "cancel_only", status: "running"
    )
  end

  describe "GET /api/v1/live_trading_sessions/:session_id/position" do
    context "session に最新 PositionSnapshot が存在する場合" do
      let!(:older_snapshot) do
        Exchange::PositionSnapshot.create!(
          live_trading_session: session, symbol: "BTCUSDT", margin_coin: "USDT",
          hold_side: "long", total: BigDecimal("0.05"), open_price_avg: BigDecimal("50000"),
          mark_price: BigDecimal("50100"), snapshot_at: 1.hour.ago
        )
      end
      let!(:latest_snapshot) do
        Exchange::PositionSnapshot.create!(
          live_trading_session: session, symbol: "BTCUSDT", margin_coin: "USDT",
          hold_side: "long", total: BigDecimal("0.07"), open_price_avg: BigDecimal("50050"),
          mark_price: BigDecimal("50200"), snapshot_at: Time.current
        )
      end

      subject { get "/api/v1/live_trading_sessions/#{session.id}/position", as: :json }

      it "200 OK + 最新 snapshot 1 件を返す" do
        subject
        expect(response).to have_http_status(:ok)
        payload = response.parsed_body
        expect(payload["id"]).to eq(latest_snapshot.id)
        expect(payload).to include(
          "live_trading_session_id" => session.id,
          "symbol" => "BTCUSDT",
          "hold_side" => "long",
          "total" => "0.07",
          "open_price_avg" => "50050.0"
        )
      end
    end

    context "session に PositionSnapshot が 1 件もない場合" do
      subject { get "/api/v1/live_trading_sessions/#{session.id}/position", as: :json }

      it "200 OK + position: null(no-position 表現)" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq("position" => nil)
      end
    end

    context "session が存在しない場合" do
      subject { get "/api/v1/live_trading_sessions/0/position", as: :json }

      it "404 Not Found を返す" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
