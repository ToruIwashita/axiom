require "rails_helper"

RSpec.describe Infrastructure::BitgetAccountEndpoint do
  let(:rest_client) { instance_double(Infrastructure::BitgetRestClient) }
  let(:endpoint) { described_class.new(rest_client: rest_client) }

  describe "#fill_history" do
    it "GET fill-history に productType / startTime / endTime を送信" do
      expect(rest_client).to receive(:request).with(
        :get,
        "/api/v2/mix/order/fill-history",
        params: {
          productType: "usdt-futures",
          startTime: 1_700_000_000_000,
          endTime: 1_700_000_999_999
        },
        auth: true,
        endpoint_key: :fill_history
      ).and_return({ "data" => [] })
      endpoint.fill_history(start_time: 1_700_000_000_000, end_time: 1_700_000_999_999)
    end

    it "symbol を指定すると symbol パラメータが追加される" do
      expect(rest_client).to receive(:request).with(
        :get,
        "/api/v2/mix/order/fill-history",
        params: hash_including(symbol: "BTCUSDT"),
        auth: true,
        endpoint_key: :fill_history
      ).and_return({ "data" => [] })
      endpoint.fill_history(
        start_time: 1_700_000_000_000,
        end_time: 1_700_000_999_999,
        symbol: "BTCUSDT"
      )
    end
  end

  describe "#account" do
    it "GET account に symbol / productType / marginCoin を送信" do
      expect(rest_client).to receive(:request).with(
        :get,
        "/api/v2/mix/account/account",
        params: {
          symbol: "BTCUSDT",
          productType: "usdt-futures",
          marginCoin: "USDT"
        },
        auth: true,
        endpoint_key: :account
      ).and_return({ "data" => {} })
      endpoint.account(margin_coin: "USDT", symbol: "BTCUSDT")
    end
  end
end
