require "rails_helper"

RSpec.describe "Api::V1::Integration::AiInvocationLogs", type: :request do
  def create_log(attrs = {})
    Integration::AiInvocationLog.create!({
      context_type: "entry_filter",
      prompt: "test prompt",
      response: "test response",
      latency_ms: 100,
      status: "success"
    }.merge(attrs))
  end

  describe "GET /api/v1/integration/ai_invocation_logs" do
    subject { get "/api/v1/integration/ai_invocation_logs", params: params }

    let(:params) { {} }

    context "ログ 0 件の場合" do
      it "200 OK + 空配列" do
        subject
        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["logs"]).to eq([])
        expect(body["total"]).to eq(0)
      end
    end

    context "ログ複数件の場合(時系列降順)" do
      let!(:log_old) { create_log(latency_ms: 50, created_at: 2.hours.ago) }
      let!(:log_new) { create_log(latency_ms: 200, created_at: 1.hour.ago) }

      it "list payload(prompt_excerpt / response_excerpt)で時系列降順返却" do
        subject
        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["logs"].map { |l| l["id"] }).to eq([ log_new.id, log_old.id ])
        first = body["logs"].first
        expect(first.keys).to match_array(%w[id context_type status prompt_excerpt response_excerpt latency_ms created_at])
        expect(first["prompt_excerpt"]).to be_a(String)
        expect(first).not_to have_key("prompt")  # 全文は含まれない
      end
    end

    context "context_type フィルタ" do
      let!(:entry_log) { create_log(context_type: "entry_filter") }
      let!(:script_log) { create_log(context_type: "script_generation") }
      let(:params) { { context_type: "entry_filter" } }

      it "指定 context_type のみ返却" do
        subject
        body = JSON.parse(response.body)
        expect(body["logs"].map { |l| l["id"] }).to eq([ entry_log.id ])
      end
    end

    context "status フィルタ" do
      let!(:success_log) { create_log(status: "success") }
      let!(:timeout_log) { create_log(status: "timeout") }
      let(:params) { { status: "timeout" } }

      it "指定 status のみ返却" do
        subject
        body = JSON.parse(response.body)
        expect(body["logs"].map { |l| l["id"] }).to eq([ timeout_log.id ])
      end
    end

    context "kaminari ページング" do
      before { 60.times { create_log } }
      let(:params) { { page: 2 } }

      it "page=2 で 51 件目以降の 10 件を返却(1 ページ 50 件)" do
        subject
        body = JSON.parse(response.body)
        expect(body["logs"].size).to eq(10)
        expect(body["total"]).to eq(60)
      end
    end
  end

  describe "GET /api/v1/integration/ai_invocation_logs/:id" do
    subject { get "/api/v1/integration/ai_invocation_logs/#{log_id}" }

    context "存在する ID の場合" do
      let!(:log) { create_log(prompt: "a" * 500, response: "b" * 500) }
      let(:log_id) { log.id }

      it "200 OK + detail payload(prompt/response 全文)" do
        subject
        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["id"]).to eq(log.id)
        expect(body["prompt"].length).to eq(500)
        expect(body["response"].length).to eq(500)
        expect(body).not_to have_key("prompt_excerpt")
      end
    end

    context "存在しない ID の場合" do
      let(:log_id) { 999_999 }

      it "404 not_found + 静的 error メッセージ(内部実装露出回避)" do
        subject
        expect(response).to have_http_status(:not_found)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("ai_invocation_log not found")
      end
    end
  end

  describe "GET /api/v1/integration/ai_invocation_logs/aggregate" do
    subject { get "/api/v1/integration/ai_invocation_logs/aggregate" }

    before do
      create_log(context_type: "entry_filter", status: "success", latency_ms: 100)
      create_log(context_type: "entry_filter", status: "timeout", latency_ms: 200)
    end

    it "200 OK + 全 7 context_type の集計 Hash" do
      subject
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.keys).to match_array(Integration::AiInvocationLog::CONTEXT_TYPES)
      stats = body["entry_filter"]
      expect(stats["total_count"]).to eq(2)
      expect(stats["success_count"]).to eq(1)
      expect(stats["success_rate"]).to eq(50.0)
    end
  end
end
