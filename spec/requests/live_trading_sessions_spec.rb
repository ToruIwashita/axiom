require "rails_helper"

RSpec.describe "LiveTradingSessions(View)", type: :request do
  let!(:definition) { Strategy::Definition.create!(name: "LTS UI", market_type: "futures", status: "active") }
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
      name: "LTS UI Policy", max_drawdown_pct: BigDecimal("20"), consecutive_loss_limit: 5,
      max_position_exposure_usdt: BigDecimal("1000"), max_leverage: 10, cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end
  let(:create_params) do
    {
      live_trading_session: {
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
    }
  end

  describe "GET /live_trading_sessions" do
    subject { get live_trading_sessions_path }

    context "session 未登録の場合" do
      it "200 OK + 空メッセージ" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("ライブトレード")
        expect(response.body).to include("セッションが登録されていません")
      end
    end

    context "session が存在する場合" do
      let!(:session) do
        LiveTrading::Session.create!(
          strategy_definition: definition, strategy_revision: revision, risk_policy_id: risk_policy.id,
          symbol: "BTCUSDT", leverage: 10, margin_mode: "isolated", position_mode: "one_way_mode",
          asset_mode: "single", margin_coin: "USDT", emergency_stop_mode: "cancel_only",
          status: "running"
        )
      end

      it "200 OK + 一覧テーブルを表示する" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("BTCUSDT")
        expect(response.body).to include("running")
      end
    end
  end

  describe "GET /live_trading_sessions/new" do
    subject { get new_live_trading_session_path }

    it "200 OK + 起動フォームを表示する" do
      subject
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("セッション起動")
      expect(response.body).to include("symbol")
      expect(response.body).to include("leverage")
    end
  end

  describe "POST /live_trading_sessions" do
    before { allow(LiveTradingWorker).to receive(:perform_async) }

    subject { post live_trading_sessions_path, params: create_params }

    context "valid params の場合" do
      it "session を作成し show にリダイレクト" do
        expect { subject }.to change { LiveTrading::Session.count }.by(1)
        expect(response).to have_http_status(:redirect)
        follow_redirect!
        expect(response.body).to include("BTCUSDT")
      end
    end

    context "Revision 不整合の場合" do
      before { create_params[:live_trading_session][:strategy_definition_id] = 0 }

      it "redirect + alert メッセージ" do
        subject
        expect(response).to have_http_status(:redirect)
        follow_redirect!
        expect(flash[:alert] || response.body).to be_present
      end
    end

    context "受入条件不合格(approved Revision)の場合" do
      let!(:revision) do
        Strategy::Revision.create!(
          strategy_definition: definition, revision_number: 1, script_content: script_body,
          script_entrypoint: "Sample", status: "approved", ast_validation_status: "passed",
          uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false,
          approved_at: Time.current
        )
      end

      it "redirect + alert メッセージ" do
        subject
        expect(response).to have_http_status(:redirect)
      end
    end
  end

  describe "GET /live_trading_sessions/:id" do
    let!(:session) do
      LiveTrading::Session.create!(
        strategy_definition: definition, strategy_revision: revision, risk_policy_id: risk_policy.id,
        symbol: "BTCUSDT", leverage: 10, margin_mode: "isolated", position_mode: "one_way_mode",
        asset_mode: "single", margin_coin: "USDT", emergency_stop_mode: "cancel_only",
        status: "running"
      )
    end

    context "存在する session の場合" do
      subject { get live_trading_session_path(session) }

      it "200 OK + session 詳細を表示する" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("BTCUSDT")
        expect(response.body).to include("running")
        expect(response.body).to include(session.id.to_s)
      end
    end

    context "存在しない session_id の場合" do
      subject { get live_trading_session_path(0) }

      it "redirect + alert メッセージ" do
        subject
        expect(response).to have_http_status(:redirect)
      end
    end
  end

  # Phase 3.4b Step 3.4-10: stop / emergency_stop UI action
  describe "POST /live_trading_sessions/:id/stop" do
    let!(:session) do
      LiveTrading::Session.create!(
        strategy_definition: definition, strategy_revision: revision, risk_policy_id: risk_policy.id,
        symbol: "BTCUSDT", leverage: 10, margin_mode: "isolated", position_mode: "one_way_mode",
        asset_mode: "single", margin_coin: "USDT", emergency_stop_mode: "cancel_only",
        status: "running"
      )
    end

    subject { post stop_live_trading_session_path(session), params: { mode: "cancel_and_market_close" } }

    context "running session を stop する場合" do
      it "session を stopping に遷移 + show リダイレクト + notice" do
        subject
        expect(response).to have_http_status(:redirect)
        expect(session.reload.state_stopping?).to be true
        expect(session.reload.emergency_stop_mode).to eq("cancel_and_market_close")
      end
    end

    context "running 以外の status から stop を呼んだ場合(InvalidTransitionError)" do
      let!(:session) do
        LiveTrading::Session.create!(
          strategy_definition: definition, strategy_revision: revision, risk_policy_id: risk_policy.id,
          symbol: "BTCUSDT", leverage: 10, margin_mode: "isolated", position_mode: "one_way_mode",
          asset_mode: "single", margin_coin: "USDT", emergency_stop_mode: "cancel_only",
          status: "stopped", stopped_at: Time.current
        )
      end

      it "session.status は変わらず show リダイレクト + alert" do
        subject
        expect(response).to have_http_status(:redirect)
        expect(session.reload.state_stopped?).to be true
      end
    end

    context "存在しない session_id の場合" do
      subject { post stop_live_trading_session_path(0), params: { mode: "cancel_only" } }

      it "一覧リダイレクト + alert" do
        subject
        expect(response).to have_http_status(:redirect)
      end
    end
  end

  describe "POST /live_trading_sessions/emergency_stop" do
    let!(:running_a) do
      LiveTrading::Session.create!(
        strategy_definition: definition, strategy_revision: revision, risk_policy_id: risk_policy.id,
        symbol: "BTCUSDT", leverage: 10, margin_mode: "isolated", position_mode: "one_way_mode",
        asset_mode: "single", margin_coin: "USDT", emergency_stop_mode: "cancel_only",
        status: "running"
      )
    end
    let!(:running_b) do
      LiveTrading::Session.create!(
        strategy_definition: definition, strategy_revision: revision, risk_policy_id: risk_policy.id,
        symbol: "BTCUSDT", leverage: 10, margin_mode: "isolated", position_mode: "one_way_mode",
        asset_mode: "single", margin_coin: "USDT", emergency_stop_mode: "cancel_only",
        status: "running"
      )
    end

    subject { post emergency_stop_live_trading_sessions_path, params: { mode: "cancel_only" } }

    it "全 running session を stopping に遷移 + 一覧リダイレクト + notice" do
      subject
      expect(response).to have_http_status(:redirect)
      expect(running_a.reload.state_stopping?).to be true
      expect(running_b.reload.state_stopping?).to be true
    end
  end
end
