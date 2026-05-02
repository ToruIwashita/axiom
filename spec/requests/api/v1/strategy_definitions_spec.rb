require "rails_helper"

RSpec.describe "Api::V1::StrategyDefinitions", type: :request do
  describe "POST /api/v1/strategy_definitions" do
    subject { post "/api/v1/strategy_definitions", params: params, as: :json }

    context "valid params の場合" do
      let(:params) { { name: "MyStrat", description: "test", market_type: "futures" } }

      it "201 Created + Definition payload を返す" do
        expect { subject }.to change { Strategy::Definition.count }.by(1)
        expect(response).to have_http_status(:created)
        body = response.parsed_body
        expect(body["name"]).to eq("MyStrat")
        expect(body["description"]).to eq("test")
        expect(body["market_type"]).to eq("futures")
        expect(body["status"]).to eq("active")
        expect(body["created_at"]).to match(/\A\d{4}-\d{2}-\d{2}T/) # iso8601(軽微 11)
      end
    end

    context "name が空の場合" do
      let(:params) { { name: "", market_type: "futures" } }

      it "422 Unprocessable Entity を返す" do
        subject
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to be_present
      end
    end
  end

  describe "GET /api/v1/strategy_definitions" do
    let!(:older) { Strategy::Definition.create!(name: "Older", market_type: "futures", status: "active", created_at: 2.days.ago) }
    let!(:newer) { Strategy::Definition.create!(name: "Newer", market_type: "futures", status: "active", created_at: 1.day.ago) }

    subject { get "/api/v1/strategy_definitions", as: :json }

    it "200 OK + 一覧を created_at desc 順で返す" do
      subject
      expect(response).to have_http_status(:ok)
      definitions = response.parsed_body["definitions"]
      expect(definitions).to be_an(Array)
      expect(definitions.first["name"]).to eq("Newer")
    end
  end

  describe "GET /api/v1/strategy_definitions/:id" do
    let!(:definition) { Strategy::Definition.create!(name: "G", market_type: "futures", status: "active") }

    context "存在する id の場合" do
      subject { get "/api/v1/strategy_definitions/#{definition.id}", as: :json }

      it "200 OK + 詳細を返す" do
        subject
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["id"]).to eq(definition.id)
        expect(body["name"]).to eq("G")
      end
    end

    context "存在しない id の場合" do
      subject { get "/api/v1/strategy_definitions/0", as: :json }

      it "404 Not Found を返す" do
        subject
        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body["error"]).to be_present
      end
    end
  end

  describe "PATCH /api/v1/strategy_definitions/:id" do
    let!(:definition) { Strategy::Definition.create!(name: "Old", market_type: "futures", status: "active") }

    subject { patch "/api/v1/strategy_definitions/#{definition.id}", params: { name: "New" }, as: :json }

    it "200 OK + 更新後 payload を返す" do
      subject
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["name"]).to eq("New")
      expect(definition.reload.name).to eq("New")
    end
  end
end
