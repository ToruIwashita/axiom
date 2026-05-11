require "rails_helper"

RSpec.describe "Api::V1::LiveTradingSessionTrades", type: :request do
  let!(:definition) { Strategy::Definition.create!(name: "LST Strat", market_type: "futures", status: "active") }
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
      name: "LST Policy", max_drawdown_pct: BigDecimal("20"), consecutive_loss_limit: 5,
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

  describe "GET /api/v1/live_trading_sessions/:session_id/trades" do
    let!(:trade1) do
      LiveTrading::Trade.create!(
        live_trading_session: session, strategy_revision: revision,
        symbol: "BTCUSDT", side: "long", quantity: BigDecimal("0.05"),
        status: "open", entry_price: BigDecimal("50000"), entry_at: 2.hours.ago
      )
    end
    let!(:trade2) do
      LiveTrading::Trade.create!(
        live_trading_session: session, strategy_revision: revision,
        symbol: "BTCUSDT", side: "short", quantity: BigDecimal("0.02"),
        status: "closed", entry_price: BigDecimal("51000"), entry_at: 1.day.ago,
        exit_price: BigDecimal("50500"), exit_at: 12.hours.ago,
        realized_pnl: BigDecimal("10")
      )
    end

    subject { get "/api/v1/live_trading_sessions/#{session.id}/trades", as: :json }

    context "session に trade が存在する場合" do
      it "200 OK + 全 trade を返す" do
        subject
        expect(response).to have_http_status(:ok)
        ids = response.parsed_body["trades"].map { |t| t["id"] }
        expect(ids).to contain_exactly(trade1.id, trade2.id)
      end

      it "各 trade payload に主要属性を含む" do
        subject
        payload = response.parsed_body["trades"].find { |t| t["id"] == trade1.id }
        expect(payload).to include(
          "id" => trade1.id,
          "live_trading_session_id" => session.id,
          "symbol" => "BTCUSDT",
          "side" => "long",
          "status" => "open",
          "quantity" => "0.05",
          "entry_price" => "50000.0"
        )
      end

      it "decimal 値は文字列で返却される(JSON 数値精度問題回避)" do
        subject
        payload = response.parsed_body["trades"].find { |t| t["id"] == trade2.id }
        expect(payload["realized_pnl"]).to eq("10.0")
      end
    end

    context "session が存在しない場合" do
      subject { get "/api/v1/live_trading_sessions/0/trades", as: :json }

      it "404 Not Found を返す" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end

    context "session に trade が 0 件の場合" do
      let!(:trade1) { nil }
      let!(:trade2) { nil }

      it "200 OK + trades: 空配列" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["trades"]).to eq([])
      end
    end
  end
end
