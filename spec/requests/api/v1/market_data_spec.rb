require "rails_helper"

RSpec.describe "Api::V1::MarketData", type: :request do
  let(:repository) { instance_double(Infrastructure::MarketDataRepository) }

  before do
    allow(Infrastructure::MarketDataRepository).to receive(:new).and_return(repository)
  end

  describe "POST /api/v1/market_data/sync" do
    subject { post "/api/v1/market_data/sync", params: params, as: :json }

    context "futures_candles を指定した場合" do
      let(:params) do
        {
          symbol: "BTCUSDT",
          data_types: %w[futures_candles],
          granularity: "1H",
          period_from: "2026-01-01T00:00:00Z",
          period_to: "2026-01-31T23:59:59Z"
        }
      end
      let(:relation) { double("Rel", size: 720) }

      before do
        allow(repository).to receive(:fetch_futures_candles).and_return(relation)
      end

      it "200 OK + 件数 Hash を返す" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq("results" => { "futures_candles" => 720 })
      end
    end

    context "未対応 data_type を含む場合" do
      let(:params) do
        {
          symbol: "BTCUSDT",
          data_types: %w[futures_candles unsupported],
          granularity: "1H",
          period_from: "2026-01-01T00:00:00Z",
          period_to: "2026-01-31T23:59:59Z"
        }
      end

      it "400 Bad Request を返す" do
        subject
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to match(/unsupported data_types/)
      end
    end
  end
end
