require "rails_helper"

RSpec.describe "StrategyRevisions(View)", type: :request do
  let!(:definition) { Strategy::Definition.create!(name: "Rev", market_type: "futures", status: "active") }
  let(:script_body) do
    <<~RUBY
      class Sample < Domain::TradingScriptBase
        def on_tick(ctx, candle); end
      end
    RUBY
  end

  describe "GET /strategy_definitions/:id/revisions" do
    subject { get strategy_definition_revisions_path(definition) }

    context "リビジョン未登録の場合" do
      it "200 OK + 空メッセージ" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("リビジョン一覧")
        expect(response.body).to include("リビジョンが登録されていません")
      end
    end

    context "リビジョンが存在する場合" do
      let!(:revision) do
        Strategy::Revision.create!(
          strategy_definition: definition, revision_number: 1, script_content: script_body,
          script_entrypoint: "Sample", status: "draft", ast_validation_status: "passed",
          uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false
        )
      end

      it "200 OK + テーブル行を表示する" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Sample")
        expect(response.body).to include("draft")
      end
    end
  end

  describe "GET /strategy_definitions/:id/revisions/new" do
    subject { get new_strategy_definition_revision_path(definition) }

    it "200 OK + フォームを表示する" do
      subject
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("新規 Revision 作成")
      expect(response.body).to include("script_entrypoint")
      expect(response.body).to include("script_content")
    end
  end

  describe "POST /strategy_definitions/:id/revisions" do
    subject do
      post strategy_definition_revisions_path(definition),
           params: {
             strategy_revision: {
               script_content: script_body,
               script_entrypoint: "Sample",
               ai_filter_enabled: "0",
               ai_sizing_enabled: "0"
             }
           }
    end

    it "draft Revision を作成し show にリダイレクト" do
      expect { subject }.to change { Strategy::Revision.count }.by(1)
      expect(response).to have_http_status(:redirect)
      follow_redirect!
      expect(response.body).to include("Revision #1")
    end
  end

  describe "GET /strategy_definitions/:id/revisions/:rev_id" do
    let!(:revision) do
      Strategy::Revision.create!(
        strategy_definition: definition, revision_number: 1, script_content: script_body,
        script_entrypoint: "Sample", status: "draft", ast_validation_status: "passed",
        uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false
      )
    end

    subject { get strategy_definition_revision_path(definition, revision) }

    it "200 OK + 詳細 + 承認ボタンを表示する(draft + ast_passed の場合)" do
      subject
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Revision #1")
      expect(response.body).to include("script_content")
      expect(response.body).to include("承認")
    end
  end

  describe "POST /strategy_definitions/:id/revisions/:rev_id/approve" do
    let!(:revision) do
      Strategy::Revision.create!(
        strategy_definition: definition, revision_number: 1, script_content: script_body,
        script_entrypoint: "Sample", status: "draft", ast_validation_status: "passed",
        uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false
      )
    end

    subject { post approve_strategy_definition_revision_path(definition, revision) }

    it "approved に遷移し show にリダイレクト" do
      subject
      expect(response).to have_http_status(:redirect)
      expect(revision.reload).to be_state_approved
    end
  end

  # Phase 3.4b Step 3.4-14: promote / deprecate / archive UI action
  describe "POST /strategy_definitions/:id/revisions/:rev_id/promote" do
    let!(:revision) do
      Strategy::Revision.create!(
        strategy_definition: definition, revision_number: 1, script_content: script_body,
        script_entrypoint: "Sample", status: "approved", ast_validation_status: "passed",
        uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false,
        approved_at: Time.current
      )
    end

    subject { post promote_strategy_definition_revision_path(definition, revision) }

    it "promoted に遷移し show にリダイレクト" do
      subject
      expect(response).to have_http_status(:redirect)
      expect(revision.reload).to be_state_promoted
    end

    context "uses_live_forbidden_input が true の場合" do
      let!(:revision) do
        Strategy::Revision.create!(
          strategy_definition: definition, revision_number: 1, script_content: script_body,
          script_entrypoint: "Sample", status: "approved", ast_validation_status: "passed",
          uses_live_forbidden_input: true, ai_filter_enabled: false, ai_sizing_enabled: false,
          approved_at: Time.current
        )
      end

      it "redirect + flash alert(LiveForbiddenInputError)で approved 維持" do
        subject
        expect(response).to have_http_status(:redirect)
        expect(revision.reload).to be_state_approved
        expect(flash[:alert]).to match(/live-forbidden/)
      end
    end
  end

  describe "POST /strategy_definitions/:id/revisions/:rev_id/deprecate" do
    let!(:revision) do
      Strategy::Revision.create!(
        strategy_definition: definition, revision_number: 1, script_content: script_body,
        script_entrypoint: "Sample", status: "promoted", ast_validation_status: "passed",
        uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false,
        approved_at: Time.current, promoted_at: Time.current
      )
    end

    subject { post deprecate_strategy_definition_revision_path(definition, revision) }

    it "deprecated に遷移し show にリダイレクト" do
      subject
      expect(response).to have_http_status(:redirect)
      expect(revision.reload).to be_state_deprecated
    end
  end

  describe "POST /strategy_definitions/:id/revisions/:rev_id/archive" do
    let!(:revision) do
      Strategy::Revision.create!(
        strategy_definition: definition, revision_number: 1, script_content: script_body,
        script_entrypoint: "Sample", status: "deprecated", ast_validation_status: "passed",
        uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false,
        approved_at: Time.current, promoted_at: Time.current, deprecated_at: Time.current
      )
    end

    subject { post archive_strategy_definition_revision_path(definition, revision) }

    it "archived に遷移し show にリダイレクト" do
      subject
      expect(response).to have_http_status(:redirect)
      expect(revision.reload).to be_state_archived
    end
  end
end
