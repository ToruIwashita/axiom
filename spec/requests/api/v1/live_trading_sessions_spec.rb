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

    # Phase 4.2 + 高-3 反映: list payload(monitoring fields + total)
    it "list payload に heartbeat / lease / ws_status / alerts + total が含まれる" do
      subject
      payload = response.parsed_body["sessions"].find { |s| s["id"] == session1.id }
      expect(payload).to include("heartbeat_elapsed_seconds", "lease_remaining_seconds", "ws_status", "alerts")
      expect(response.parsed_body["total"]).to eq(2)
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

      # Phase 4.2 + 高-3 反映: detail payload(monitoring fields)
      it "detail payload に heartbeat / lease / ws_reconnect_status / alerts が含まれる" do
        subject
        expect(response.parsed_body).to include(
          "heartbeat_elapsed_seconds", "lease_remaining_seconds",
          "lease_status", "lease_expires_at", "last_heartbeat_at",
          "ws_reconnect_status", "alerts"
        )
      end
    end

    context "存在しない session_id の場合" do
      subject { get "/api/v1/live_trading_sessions/0", as: :json }

      it "404 Not Found + 静的メッセージ(内部実装露出回避)" do
        subject
        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body["error"]).to eq("live_trading_session not found")
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

  # Phase 3.4b Step 3.4-6: stop / emergency_stop endpoint
  describe "POST /api/v1/live_trading_sessions/:id/stop" do
    let!(:session) do
      LiveTrading::Session.create!(
        create_params.merge(status: "running", started_at: Time.current)
      )
    end

    subject do
      post "/api/v1/live_trading_sessions/#{session.id}/stop",
           params: { mode: "cancel_and_market_close" }, as: :json
    end

    context "running session を stop する場合" do
      it "200 OK + stopping status + emergency_stop_mode が上書きされる" do
        subject
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["status"]).to eq("stopping")
        expect(body["emergency_stop_mode"]).to eq("cancel_and_market_close")
        expect(session.reload.state_stopping?).to be true
      end
    end

    context "running 以外の status から stop を呼んだ場合(InvalidTransitionError)" do
      let!(:session) do
        LiveTrading::Session.create!(
          create_params.merge(status: "stopped", started_at: Time.current, stopped_at: Time.current)
        )
      end

      it "422 Unprocessable Entity を返す" do
        subject
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to match(/cannot start_stopping/i)
      end
    end

    context "存在しない session_id を指定した場合" do
      subject do
        post "/api/v1/live_trading_sessions/0/stop",
             params: { mode: "cancel_only" }, as: :json
      end

      it "404 Not Found を返す" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end

    context "mode 不正値(EMERGENCY_STOP_MODES 外)で stop した場合" do
      subject do
        post "/api/v1/live_trading_sessions/#{session.id}/stop",
             params: { mode: "invalid_mode" }, as: :json
      end

      it "400 Bad Request を返す(Service 入口 Fail Fast)" do
        subject
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to match(/mode must be one of/)
      end
    end
  end

  describe "POST /api/v1/live_trading_sessions/emergency_stop" do
    let!(:running_session_a) do
      LiveTrading::Session.create!(
        create_params.merge(status: "running", started_at: Time.current)
      )
    end
    let!(:running_session_b) do
      LiveTrading::Session.create!(
        create_params.merge(status: "running", started_at: Time.current)
      )
    end
    let!(:stopped_session) do
      LiveTrading::Session.create!(
        create_params.merge(status: "stopped", started_at: Time.current, stopped_at: Time.current)
      )
    end

    subject do
      post "/api/v1/live_trading_sessions/emergency_stop",
           params: { mode: "cancel_only" }, as: :json
    end

    context "running session が複数存在する場合" do
      it "200 OK + 全 running session を stopping に遷移させる" do
        subject
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["sessions"].map { |s| s["id"] }).to contain_exactly(running_session_a.id, running_session_b.id)
        expect(body["sessions"].map { |s| s["status"] }).to all(eq("stopping"))
        expect(running_session_a.reload.state_stopping?).to be true
        expect(running_session_b.reload.state_stopping?).to be true
      end

      it "stopped 等の terminal session は対象外(状態維持)" do
        subject
        expect(stopped_session.reload.state_stopped?).to be true
      end
    end

    context "running session が 0 件の場合" do
      let!(:running_session_a) { nil }
      let!(:running_session_b) { nil }

      it "200 OK + sessions: 空配列" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["sessions"]).to eq([])
      end
    end
  end
end
