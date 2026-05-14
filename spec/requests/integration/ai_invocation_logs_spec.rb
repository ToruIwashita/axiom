require "rails_helper"

RSpec.describe "Integration::AiInvocationLogs(View)", type: :request do
  def create_log(attrs = {})
    Integration::AiInvocationLog.create!({
      context_type: "entry_filter",
      prompt: "test prompt",
      response: "test response",
      latency_ms: 100,
      status: "success"
    }.merge(attrs))
  end

  describe "GET /integration/ai_invocation_logs" do
    subject { get "/integration/ai_invocation_logs", params: params }

    let(:params) { {} }

    context "ログ 0 件の場合" do
      it "200 OK + 空状態メッセージ表示" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("AI Invocation Logs")
        expect(response.body).to include("該当する AI 呼び出しログが存在しません")
      end
    end

    context "ログ存在 + filter なし" do
      let!(:log) { create_log(latency_ms: 250) }

      it "200 OK + 一覧 table 表示 + filter フォーム表示" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("entry_filter")
        expect(response.body).to include("250")
        expect(response.body).to include("Context Type:")
        expect(response.body).to include("Status:")
      end
    end

    context "context_type filter 指定" do
      let!(:entry_log) { create_log(context_type: "entry_filter") }
      let!(:script_log) { create_log(context_type: "script_generation") }
      let(:params) { { context_type: "entry_filter" } }

      it "指定 context_type のみ表示(他は table 行に含まれない)" do
        subject
        expect(response.body).to include(entry_log.id.to_s)
        expect(response.body).not_to match(/<td>#{script_log.id}<\/td>/)
      end
    end
  end

  describe "GET /integration/ai_invocation_logs/:id" do
    subject { get "/integration/ai_invocation_logs/#{log_id}" }

    context "存在する ID の場合" do
      let!(:log) { create_log(prompt: "full prompt content", response: "full response content") }
      let(:log_id) { log.id }

      it "200 OK + 詳細表示(prompt/response 全文)" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("AI Invocation Log ##{log.id}")
        expect(response.body).to include("full prompt content")
        expect(response.body).to include("full response content")
      end
    end

    context "存在しない ID の場合" do
      let(:log_id) { 999_999 }

      it "一覧へリダイレクト + alert flash" do
        subject
        expect(response).to redirect_to(integration_ai_invocation_logs_path)
        expect(flash[:alert]).to include("ログが見つかりませんでした")
      end
    end
  end
end
