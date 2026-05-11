require "rails_helper"

RSpec.describe "Api::V1::StrategyRevisions", type: :request do
  let!(:definition) { Strategy::Definition.create!(name: "Rev Strat", market_type: "futures", status: "active") }
  let(:script_body) do
    <<~RUBY
      class Sample < Domain::TradingScriptBase
        def on_tick(ctx, candle); end
      end
    RUBY
  end

  describe "POST /api/v1/strategy_definitions/:id/revisions" do
    subject do
      post "/api/v1/strategy_definitions/#{definition.id}/revisions",
           params: { script_content: script_body, script_entrypoint: "Sample" },
           as: :json
    end

    context "valid params の場合" do
      it "201 Created + draft Revision payload を返す" do
        expect { subject }.to change { Strategy::Revision.count }.by(1)
        expect(response).to have_http_status(:created)
        body = response.parsed_body
        expect(body["status"]).to eq("draft")
        expect(body["revision_number"]).to eq(1)
        expect(body["ast_validation_status"]).to eq("passed")
        expect(body["script_entrypoint"]).to eq("Sample")
      end
    end

    context "Definition が存在しない場合" do
      subject do
        post "/api/v1/strategy_definitions/0/revisions",
             params: { script_content: script_body, script_entrypoint: "Sample" },
             as: :json
      end

      it "404 Not Found を返す" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /api/v1/strategy_definitions/:id/revisions" do
    let!(:r1) do
      Strategy::Revision.create!(
        strategy_definition: definition, revision_number: 1, script_content: script_body,
        script_entrypoint: "Sample", status: "draft", ast_validation_status: "passed",
        uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false
      )
    end
    let!(:r2) do
      Strategy::Revision.create!(
        strategy_definition: definition, revision_number: 2, script_content: script_body,
        script_entrypoint: "Sample", status: "draft", ast_validation_status: "passed",
        uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false
      )
    end

    subject { get "/api/v1/strategy_definitions/#{definition.id}/revisions", as: :json }

    it "200 OK + revision_number desc 順で返す" do
      subject
      expect(response).to have_http_status(:ok)
      revisions = response.parsed_body["revisions"]
      expect(revisions.first["revision_number"]).to eq(2)
      expect(revisions.last["revision_number"]).to eq(1)
    end
  end

  describe "GET /api/v1/strategy_definitions/:id/revisions/:rev_id" do
    let!(:revision) do
      Strategy::Revision.create!(
        strategy_definition: definition, revision_number: 1, script_content: script_body,
        script_entrypoint: "Sample", status: "draft", ast_validation_status: "passed",
        uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false
      )
    end

    context "存在する場合" do
      subject { get "/api/v1/strategy_definitions/#{definition.id}/revisions/#{revision.id}", as: :json }

      it "200 OK + 詳細を返す" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["id"]).to eq(revision.id)
      end
    end

    context "存在しない場合" do
      subject { get "/api/v1/strategy_definitions/#{definition.id}/revisions/0", as: :json }

      it "404 Not Found を返す" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # Phase 3.4b Step 3.4-4: promote / deprecate / archive 3 action 追加
  describe "POST /api/v1/strategy_definitions/:id/revisions/:rev_id/promote" do
    let!(:revision) do
      Strategy::Revision.create!(
        strategy_definition: definition, revision_number: 1, script_content: script_body,
        script_entrypoint: "Sample", status: "approved", ast_validation_status: "passed",
        uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false,
        approved_at: Time.current
      )
    end

    subject { post "/api/v1/strategy_definitions/#{definition.id}/revisions/#{revision.id}/promote", as: :json }

    context "approved Revision を promote する場合" do
      it "200 OK + promoted に遷移する" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["status"]).to eq("promoted")
        expect(revision.reload).to be_state_promoted
      end
    end

    context "uses_live_forbidden_input が true の Revision を promote する場合" do
      let!(:revision) do
        Strategy::Revision.create!(
          strategy_definition: definition, revision_number: 1, script_content: script_body,
          script_entrypoint: "Sample", status: "approved", ast_validation_status: "passed",
          uses_live_forbidden_input: true, ai_filter_enabled: false, ai_sizing_enabled: false,
          approved_at: Time.current
        )
      end

      it "422 Unprocessable Entity を返す(LiveForbiddenInputError)" do
        subject
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to match(/live-forbidden/)
      end
    end

    context "存在しない revision_id を指定した場合" do
      subject { post "/api/v1/strategy_definitions/#{definition.id}/revisions/0/promote", as: :json }

      it "404 Not Found を返す" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /api/v1/strategy_definitions/:id/revisions/:rev_id/deprecate" do
    let!(:revision) do
      Strategy::Revision.create!(
        strategy_definition: definition, revision_number: 1, script_content: script_body,
        script_entrypoint: "Sample", status: "promoted", ast_validation_status: "passed",
        uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false,
        approved_at: Time.current, promoted_at: Time.current
      )
    end

    subject { post "/api/v1/strategy_definitions/#{definition.id}/revisions/#{revision.id}/deprecate", as: :json }

    context "promoted Revision を deprecate する場合" do
      it "200 OK + deprecated に遷移する" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["status"]).to eq("deprecated")
        expect(revision.reload).to be_state_deprecated
      end
    end

    context "存在しない revision_id を指定した場合" do
      subject { post "/api/v1/strategy_definitions/#{definition.id}/revisions/0/deprecate", as: :json }

      it "404 Not Found を返す" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /api/v1/strategy_definitions/:id/revisions/:rev_id/archive" do
    let!(:revision) do
      Strategy::Revision.create!(
        strategy_definition: definition, revision_number: 1, script_content: script_body,
        script_entrypoint: "Sample", status: "deprecated", ast_validation_status: "passed",
        uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false,
        approved_at: Time.current, promoted_at: Time.current, deprecated_at: Time.current
      )
    end

    subject { post "/api/v1/strategy_definitions/#{definition.id}/revisions/#{revision.id}/archive", as: :json }

    context "任意 status の Revision を archive する場合" do
      it "200 OK + archived に遷移する" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["status"]).to eq("archived")
        expect(revision.reload).to be_state_archived
      end
    end

    context "存在しない revision_id を指定した場合" do
      subject { post "/api/v1/strategy_definitions/#{definition.id}/revisions/0/archive", as: :json }

      it "404 Not Found を返す" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /api/v1/strategy_definitions/:id/revisions/:rev_id/approve" do
    let!(:revision) do
      Strategy::Revision.create!(
        strategy_definition: definition, revision_number: 1, script_content: script_body,
        script_entrypoint: "Sample", status: "draft", ast_validation_status: "passed",
        uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false
      )
    end

    subject { post "/api/v1/strategy_definitions/#{definition.id}/revisions/#{revision.id}/approve", as: :json }

    context "draft + AST 再検証 passed の場合" do
      it "200 OK + approved に遷移する" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["status"]).to eq("approved")
        expect(revision.reload).to be_state_approved
      end
    end

    context "draft 以外の Revision を approve する場合" do
      let!(:revision) do
        Strategy::Revision.create!(
          strategy_definition: definition, revision_number: 1, script_content: script_body,
          script_entrypoint: "Sample", status: "approved", ast_validation_status: "passed",
          uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false,
          approved_at: Time.current
        )
      end

      it "422 Unprocessable Entity を返す" do
        subject
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to match(/must be draft/)
      end
    end
  end
end
