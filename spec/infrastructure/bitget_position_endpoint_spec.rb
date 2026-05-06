require "rails_helper"

RSpec.describe Infrastructure::BitgetPositionEndpoint do
  let(:rest_client) { instance_double(Infrastructure::BitgetRestClient) }
  let(:endpoint) { described_class.new(rest_client: rest_client) }

  describe "#position_all" do
    it "GET all-position に productType + marginCoin を送信" do
      expect(rest_client).to receive(:request).with(
        :get,
        "/api/v2/mix/position/all-position",
        params: { productType: "usdt-futures", marginCoin: "USDT" },
        auth: true,
        endpoint_key: :position_all
      ).and_return({ "data" => [] })
      endpoint.position_all(margin_coin: "USDT")
    end

    it "symbol を指定すると symbol パラメータが追加される" do
      expect(rest_client).to receive(:request).with(
        :get,
        "/api/v2/mix/position/all-position",
        params: { productType: "usdt-futures", marginCoin: "USDT", symbol: "BTCUSDT" },
        auth: true,
        endpoint_key: :position_all
      ).and_return({ "data" => [] })
      endpoint.position_all(margin_coin: "USDT", symbol: "BTCUSDT")
    end
  end

  describe "#set_margin_mode" do
    it "POST set-margin-mode に必要フィールドを送信" do
      expect(rest_client).to receive(:request) do |method, path, **kwargs|
        expect(method).to eq(:post)
        expect(path).to eq("/api/v2/mix/account/set-margin-mode")
        body = JSON.parse(kwargs[:body])
        expect(body).to include(
          "symbol" => "BTCUSDT",
          "productType" => "usdt-futures",
          "marginCoin" => "USDT",
          "marginMode" => "isolated"
        )
        expect(kwargs[:endpoint_key]).to eq(:set_margin_mode)
        { "data" => {} }
      end
      endpoint.set_margin_mode(symbol: "BTCUSDT", margin_coin: "USDT", margin_mode: "isolated")
    end
  end

  describe "#set_position_mode" do
    it "POST set-position-mode に productType + posMode を送信" do
      expect(rest_client).to receive(:request) do |_method, path, **kwargs|
        expect(path).to eq("/api/v2/mix/account/set-position-mode")
        body = JSON.parse(kwargs[:body])
        expect(body).to include(
          "productType" => "usdt-futures",
          "posMode" => "hedge_mode"
        )
        { "data" => {} }
      end
      endpoint.set_position_mode(position_mode: "hedge_mode")
    end
  end

  describe "#set_asset_mode" do
    it "POST set-asset-mode に productType + assetMode を送信" do
      expect(rest_client).to receive(:request) do |_method, path, **kwargs|
        expect(path).to eq("/api/v2/mix/account/set-asset-mode")
        body = JSON.parse(kwargs[:body])
        expect(body).to include(
          "productType" => "usdt-futures",
          "assetMode" => "union"
        )
        { "data" => {} }
      end
      endpoint.set_asset_mode(asset_mode: "union")
    end
  end

  describe "#set_leverage" do
    context "one_way_mode(hold_side 省略)の場合" do
      it "POST set-leverage に symbol / marginCoin / leverage を送信(holdSide なし)" do
        expect(rest_client).to receive(:request) do |_method, path, **kwargs|
          expect(path).to eq("/api/v2/mix/account/set-leverage")
          body = JSON.parse(kwargs[:body])
          expect(body).to include(
            "symbol" => "BTCUSDT",
            "productType" => "usdt-futures",
            "marginCoin" => "USDT",
            "leverage" => "10"
          )
          expect(body["holdSide"]).to be_nil
          { "data" => {} }
        end
        endpoint.set_leverage(symbol: "BTCUSDT", margin_coin: "USDT", leverage: 10)
      end
    end

    context "hedge_mode(hold_side 指定)の場合" do
      it "holdSide が含まれる" do
        expect(rest_client).to receive(:request) do |_method, _path, **kwargs|
          body = JSON.parse(kwargs[:body])
          expect(body["holdSide"]).to eq("long")
          { "data" => {} }
        end
        endpoint.set_leverage(
          symbol: "BTCUSDT", margin_coin: "USDT", leverage: 10, hold_side: "long"
        )
      end
    end
  end
end
