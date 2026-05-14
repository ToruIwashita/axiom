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

    # multi-agent review Agent 2 spec 中 反映: 60 件超で paginate リンク描画
    context "60 件超で paginate リンク表示" do
      before { 60.times { create_log } }

      it "?page=2 リンクが描画される(kaminari)" do
        subject
        expect(response.body).to include("page=2")
      end
    end

    # multi-agent review Agent 2 中-2 反映: 不正 context_type で alert + リダイレクト
    context "不正 context_type filter の場合" do
      let(:params) { { context_type: "unknown_type" } }

      it "一覧へリダイレクト + 不正フィルタ alert" do
        subject
        expect(response).to redirect_to(integration_ai_invocation_logs_path)
        expect(flash[:alert]).to eq("不正なフィルタ値が指定されました")
      end
    end

    # multi-agent review 再実施 Agent 4 M-2 反映: status 側の enum 違反対称性
    context "不正 status filter の場合" do
      let(:params) { { status: "unknown_status" } }

      it "一覧へリダイレクト + 不正フィルタ alert" do
        subject
        expect(response).to redirect_to(integration_ai_invocation_logs_path)
        expect(flash[:alert]).to eq("不正なフィルタ値が指定されました")
      end
    end

    # multi-agent review 再実施 Agent 4 M-3 反映: kaminari 異常 page 値ガード検証
    context "params[:page] が異常値の場合" do
      before { 3.times { create_log } }

      context "page='abc' の非数値文字列" do
        let(:params) { { page: "abc" } }

        it "200 OK で 1 ページ目を返す(kaminari fallback)" do
          subject
          expect(response).to have_http_status(:ok)
          expect(response.body).to include("AI Invocation Logs")
        end
      end

      context "page=99999 の max_pages 超過" do
        let(:params) { { page: 99999 } }

        it "200 OK(max_pages=1000 ガード or 範囲外で空状態描画)" do
          subject
          expect(response).to have_http_status(:ok)
        end
      end
    end

    # multi-agent review Agent 2 + 再実施 Agent 4 M-6 反映:
    # _status_badge 4 status × 4 色分岐 を厳密検証(全部同一色のリグレッション検出)
    EXPECTED_BADGE_COLORS = {
      "success"           => "#2e7d32",
      "timeout"           => "#ef6c00",
      "error"             => "#c62828",
      "validation_failed" => "#6a1b9a"
    }.freeze

    context "_status_badge の 4 status 色分岐(色値厳密検証 / 対称性)" do
      Integration::AiInvocationLog::STATUSES.each do |status|
        context "status=#{status} の場合" do
          let!(:log) { create_log(status: status) }

          it "status 固有の background-color が描画される(全色同一リグレッション防止)" do
            subject
            expect(response.body).to include("background:#{EXPECTED_BADGE_COLORS.fetch(status)}")
            expect(response.body).to include(status)
          end
        end
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

  describe "GET /integration/ai_invocation_logs/aggregate" do
    subject { get "/integration/ai_invocation_logs/aggregate" }

    context "ログ存在の場合" do
      before do
        create_log(context_type: "entry_filter", status: "success", latency_ms: 100)
        create_log(context_type: "entry_filter", status: "timeout", latency_ms: 200)
      end

      it "200 OK + 集計テーブル表示(7 context_type 全件)" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("AI Invocation Log 集計")
        expect(response.body).to include("entry_filter")
        Integration::AiInvocationLog::CONTEXT_TYPES.each do |ct|
          expect(response.body).to include(ct)
        end
      end
    end

    # multi-agent review 再実施 Agent 4 M-1 反映: 0 件時の集計テーブル表示(7 行 0 表示)
    context "ログ 0 件の場合" do
      it "200 OK + 集計テーブルは 7 context_type 行で 0 表示" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("AI Invocation Log 集計")
        Integration::AiInvocationLog::CONTEXT_TYPES.each do |ct|
          expect(response.body).to include(ct)
        end
      end
    end
  end
end
