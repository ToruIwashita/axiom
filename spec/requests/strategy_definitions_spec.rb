require "rails_helper"

RSpec.describe "StrategyDefinitions(View)", type: :request do
  describe "GET /strategy_definitions" do
    subject { get strategy_definitions_path }

    context "戦略定義が空の場合" do
      it "200 OK + 空メッセージを表示する" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("戦略定義一覧")
        expect(response.body).to include("戦略定義が登録されていません")
      end
    end

    context "戦略定義が存在する場合" do
      let!(:definition) { Strategy::Definition.create!(name: "Sample", market_type: "futures", status: "active") }

      it "200 OK + テーブル行を表示する" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Sample")
        expect(response.body).to include("futures")
      end
    end
  end

  describe "GET /strategy_definitions/new" do
    subject { get new_strategy_definition_path }

    it "200 OK + フォームを表示する" do
      subject
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("戦略定義を新規作成")
      expect(response.body).to include("name")
    end
  end

  describe "POST /strategy_definitions" do
    subject do
      post strategy_definitions_path,
           params: { strategy_definition: { name: "X", description: "y", market_type: "futures" } }
    end

    it "Definition を作成し show にリダイレクトする" do
      expect { subject }.to change { Strategy::Definition.count }.by(1)
      expect(response).to have_http_status(:redirect)
      follow_redirect!
      expect(response.body).to include("X")
    end
  end

  describe "GET /strategy_definitions/:id" do
    let!(:definition) { Strategy::Definition.create!(name: "ShowMe", market_type: "futures", status: "active") }

    subject { get strategy_definition_path(definition) }

    it "200 OK + 詳細を表示する" do
      subject
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("ShowMe")
      expect(response.body).to include("リビジョン一覧")
    end
  end
end
