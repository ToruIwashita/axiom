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
