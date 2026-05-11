require "rails_helper"

RSpec.describe "Api::V1::LiveTradingSessions", type: :request do
  let!(:definition) { Strategy::Definition.create!(name: "LTS Strat", market_type: "futures", status: "active") }
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
      name: "LTS Policy", max_drawdown_pct: BigDecimal("20"), consecutive_loss_limit: 5,
      max_position_exposure_usdt: BigDecimal("1000"), max_leverage: 10, cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end
  let(:create_params) do
    {
      strategy_definition_id: definition.id,
      strategy_revision_id: revision.id,
      risk_policy_id: risk_policy.id,
      symbol: "BTCUSDT",
      leverage: 10,
      margin_mode: "isolated",
      position_mode: "one_way_mode",
      asset_mode: "single",
      margin_coin: "USDT",
      emergency_stop_mode: "cancel_only"
    }
  end

  describe "GET /api/v1/live_trading_sessions" do
    let!(:session1) do
      LiveTrading::Session.create!(
        create_params.merge(status: "running")
      )
    end
    let!(:session2) do
      LiveTrading::Session.create!(
        create_params.merge(status: "stopped")
      )
    end

    subject { get "/api/v1/live_trading_sessions", as: :json }

    it "200 OK + 全 session の一覧を返す" do
      subject
      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["sessions"].map { |s| s["id"] }
      expect(ids).to contain_exactly(session1.id, session2.id)
    end

    it "各 session payload に主要属性を含む" do
      subject
      payload = response.parsed_body["sessions"].find { |s| s["id"] == session1.id }
      expect(payload).to include(
        "id" => session1.id,
        "strategy_definition_id" => definition.id,
        "strategy_revision_id" => revision.id,
        "risk_policy_id" => risk_policy.id,
        "symbol" => "BTCUSDT",
        "status" => "running",
        "margin_mode" => "isolated",
        "position_mode" => "one_way_mode"
      )
    end
  end

  describe "GET /api/v1/live_trading_sessions/:id" do
    let!(:session) do
      LiveTrading::Session.create!(
        create_params.merge(status: "running", started_at: Time.current)
      )
    end

    context "存在する session の場合" do
      subject { get "/api/v1/live_trading_sessions/#{session.id}", as: :json }

      it "200 OK + session payload を返す" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include(
          "id" => session.id,
          "status" => "running",
          "leverage" => 10,
          "emergency_stop_mode" => "cancel_only"
        )
      end
    end

    context "存在しない session_id の場合" do
      subject { get "/api/v1/live_trading_sessions/0", as: :json }

      it "404 Not Found を返す" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /api/v1/live_trading_sessions" do
    before { allow(LiveTradingWorker).to receive(:perform_async) }

    subject { post "/api/v1/live_trading_sessions", params: create_params, as: :json }

    context "valid params の場合" do
      it "201 Created + starting status + LiveTradingWorker enqueue" do
        expect { subject }.to change { LiveTrading::Session.count }.by(1)
        expect(response).to have_http_status(:created)
        body = response.parsed_body
        expect(body["status"]).to eq("starting")
        expect(body["symbol"]).to eq("BTCUSDT")
        expect(LiveTradingWorker).to have_received(:perform_async).with(LiveTrading::Session.last.id)
      end
    end

    context "Strategy::Revision と Strategy::Definition が不整合の場合(整合検証 400)" do
      let(:other_definition) { Strategy::Definition.create!(name: "Other", market_type: "futures", status: "active") }

      before { create_params[:strategy_definition_id] = other_definition.id }

      it "400 Bad Request を返す" do
        expect { subject }.not_to change { LiveTrading::Session.count }
        expect(response).to have_http_status(:bad_request)
      end
    end

    context "Revision が approved (= 受入条件不合格 / 422)" do
      let!(:revision) do
        Strategy::Revision.create!(
          strategy_definition: definition, revision_number: 1, script_content: script_body,
          script_entrypoint: "Sample", status: "approved", ast_validation_status: "passed",
          uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false,
          approved_at: Time.current
        )
      end

      it "422 Unprocessable Entity を返す(promoted のみ acceptable)" do
        expect { subject }.not_to change { LiveTrading::Session.count }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to match(/not acceptable for live/)
      end
    end

    context "Revision の uses_live_forbidden_input が true の場合(受入条件不合格 / 422)" do
      let!(:revision) do
        Strategy::Revision.create!(
          strategy_definition: definition, revision_number: 1, script_content: script_body,
          script_entrypoint: "Sample", status: "promoted", ast_validation_status: "passed",
          uses_live_forbidden_input: true, ai_filter_enabled: false, ai_sizing_enabled: false,
          approved_at: Time.current, promoted_at: Time.current
        )
      end

      it "422 Unprocessable Entity を返す" do
        expect { subject }.not_to change { LiveTrading::Session.count }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to match(/uses_live_forbidden_input/)
      end
    end

    context "存在しない strategy_revision_id を指定した場合" do
      before { create_params[:strategy_revision_id] = 0 }

      it "404 Not Found を返す" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
