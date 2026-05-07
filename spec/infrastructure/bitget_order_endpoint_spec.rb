require "rails_helper"

RSpec.describe Infrastructure::BitgetOrderEndpoint do
  let(:rest_client) { instance_double(Infrastructure::BitgetRestClient) }
  let(:endpoint) { described_class.new(rest_client: rest_client) }

  describe "#place_order" do
    subject do
      endpoint.place_order(
        symbol: "BTCUSDT",
        margin_mode: "isolated",
        margin_coin: "USDT",
        side: "buy",
        order_type: "limit",
        size: BigDecimal("0.01"),
        price: BigDecimal("50000"),
        force: "gtc",
        reduce_only: "no",
        client_oid: "client-oid-1"
      )
    end

    it "POST /api/v2/mix/order/place-order に必須フィールド(marginMode/marginCoin 含む)を送信" do
      expect(rest_client).to receive(:request) do |method, path, **kwargs|
        expect(method).to eq(:post)
        expect(path).to eq("/api/v2/mix/order/place-order")
        expect(kwargs[:auth]).to be true
        expect(kwargs[:endpoint_key]).to eq(:place_order)
        body = JSON.parse(kwargs[:body])
        expect(body).to include(
          "symbol" => "BTCUSDT",
          "productType" => "usdt-futures",
          "marginMode" => "isolated",
          "marginCoin" => "USDT",
          "side" => "buy",
          "orderType" => "limit",
          "size" => "0.01",
          "price" => "50000.0",
          "force" => "gtc",
          "reduceOnly" => "no",
          "clientOid" => "client-oid-1"
        )
        { "data" => { "orderId" => "12345" } }
      end
      subject
    end

    context "margin_mode が crossed の場合" do
      it "marginMode=crossed が body に含まれる" do
        expect(rest_client).to receive(:request) do |_method, _path, **kwargs|
          body = JSON.parse(kwargs[:body])
          expect(body["marginMode"]).to eq("crossed")
          { "data" => {} }
        end
        endpoint.place_order(
          symbol: "BTCUSDT", margin_mode: "crossed", margin_coin: "USDT",
          side: "buy", order_type: "market",
          size: BigDecimal("0.01"), force: "gtc", reduce_only: "no", client_oid: "x"
        )
      end
    end

    context "TP/SL 委託価格を指定する場合" do
      it "presetStopSurplusPrice / presetStopLossPrice を含む" do
        expect(rest_client).to receive(:request) do |_method, _path, **kwargs|
          body = JSON.parse(kwargs[:body])
          expect(body["presetStopSurplusPrice"]).to eq("51000.0")
          expect(body["presetStopLossPrice"]).to eq("49000.0")
          { "data" => {} }
        end
        endpoint.place_order(
          symbol: "BTCUSDT", margin_mode: "isolated", margin_coin: "USDT",
          side: "buy", order_type: "market",
          size: BigDecimal("0.01"), force: "gtc", reduce_only: "no", client_oid: "x",
          preset_stop_surplus_price: BigDecimal("51000"),
          preset_stop_loss_price: BigDecimal("49000")
        )
      end
    end

    context "hedge_mode で trade_side=open の場合" do
      it "tradeSide=open が含まれる" do
        expect(rest_client).to receive(:request) do |_method, _path, **kwargs|
          body = JSON.parse(kwargs[:body])
          expect(body["tradeSide"]).to eq("open")
          { "data" => {} }
        end
        endpoint.place_order(
          symbol: "BTCUSDT", margin_mode: "isolated", margin_coin: "USDT",
          side: "buy", order_type: "market",
          size: BigDecimal("0.01"), force: "gtc", reduce_only: "no",
          client_oid: "x", trade_side: "open"
        )
      end
    end

    context "margin_mode / margin_coin が省略された場合" do
      it "ArgumentError raise(キーワード引数必須)" do
        expect do
          endpoint.place_order(
            symbol: "BTCUSDT", side: "buy", order_type: "market",
            size: BigDecimal("0.01"), force: "gtc", reduce_only: "no", client_oid: "x"
          )
        end.to raise_error(ArgumentError)
      end
    end
  end

  describe "#cancel_order" do
    context "order_id 指定の場合" do
      it "POST cancel-order に orderId を含む" do
        expect(rest_client).to receive(:request) do |method, path, **kwargs|
          expect(method).to eq(:post)
          expect(path).to eq("/api/v2/mix/order/cancel-order")
          body = JSON.parse(kwargs[:body])
          expect(body).to include("orderId" => "order-1")
          expect(body["clientOid"]).to be_nil
          { "data" => {} }
        end
        endpoint.cancel_order(symbol: "BTCUSDT", order_id: "order-1")
      end
    end

    context "client_oid のみ指定の場合" do
      it "clientOid を含む" do
        expect(rest_client).to receive(:request) do |_method, _path, **kwargs|
          body = JSON.parse(kwargs[:body])
          expect(body["clientOid"]).to eq("client-oid-1")
          { "data" => {} }
        end
        endpoint.cancel_order(symbol: "BTCUSDT", client_oid: "client-oid-1")
      end
    end

    context "order_id / client_oid 両方 nil の場合" do
      it "ArgumentError raise" do
        expect { endpoint.cancel_order(symbol: "BTCUSDT") }
          .to raise_error(ArgumentError, /order_id or client_oid/)
      end
    end
  end

  describe "#modify_order" do
    it "POST modify-order に新価格 / 新サイズを含む" do
      expect(rest_client).to receive(:request) do |method, path, **kwargs|
        expect(method).to eq(:post)
        expect(path).to eq("/api/v2/mix/order/modify-order")
        body = JSON.parse(kwargs[:body])
        expect(body).to include(
          "symbol" => "BTCUSDT",
          "orderId" => "order-1",
          "newPrice" => "51000.0",
          "newSize" => "0.02"
        )
        { "data" => {} }
      end
      endpoint.modify_order(
        symbol: "BTCUSDT", order_id: "order-1",
        new_price: BigDecimal("51000"), new_size: BigDecimal("0.02")
      )
    end
  end

  describe "#orders_pending" do
    it "GET orders-pending に productType を送信" do
      expect(rest_client).to receive(:request).with(
        :get,
        "/api/v2/mix/order/orders-pending",
        params: { productType: "usdt-futures", symbol: "BTCUSDT" },
        auth: true,
        endpoint_key: :orders_pending
      ).and_return({ "data" => [] })
      endpoint.orders_pending(symbol: "BTCUSDT")
    end

    it "symbol 省略時は productType のみ送信" do
      expect(rest_client).to receive(:request).with(
        :get,
        "/api/v2/mix/order/orders-pending",
        params: { productType: "usdt-futures" },
        auth: true,
        endpoint_key: :orders_pending
      ).and_return({ "data" => [] })
      endpoint.orders_pending
    end
  end

  describe "#orders_plan_pending" do
    it "GET orders-plan-pending に productType を送信" do
      expect(rest_client).to receive(:request).with(
        :get,
        "/api/v2/mix/order/orders-plan-pending",
        params: { productType: "usdt-futures" },
        auth: true,
        endpoint_key: :orders_plan_pending
      ).and_return({ "data" => [] })
      endpoint.orders_plan_pending
    end
  end

  describe "#orders_plan_history" do
    it "GET orders-plan-history に startTime / endTime を送信" do
      expect(rest_client).to receive(:request).with(
        :get,
        "/api/v2/mix/order/orders-plan-history",
        params: {
          productType: "usdt-futures",
          startTime: 1_700_000_000_000,
          endTime: 1_700_000_999_999
        },
        auth: true,
        endpoint_key: :orders_plan_history
      ).and_return({ "data" => [] })
      endpoint.orders_plan_history(start_time: 1_700_000_000_000, end_time: 1_700_000_999_999)
    end
  end

  describe "#plan_sub_order" do
    it "GET plan-sub-order に planId を送信" do
      expect(rest_client).to receive(:request).with(
        :get,
        "/api/v2/mix/order/plan-sub-order",
        params: { productType: "usdt-futures", planId: "plan-1" },
        auth: true,
        endpoint_key: :plan_sub_order
      ).and_return({ "data" => [] })
      endpoint.plan_sub_order(plan_id: "plan-1")
    end
  end

  describe "#order_detail" do
    it "GET detail に symbol / orderId を送信" do
      expect(rest_client).to receive(:request).with(
        :get,
        "/api/v2/mix/order/detail",
        params: { productType: "usdt-futures", symbol: "BTCUSDT", orderId: "order-1" },
        auth: true,
        endpoint_key: :order_detail
      ).and_return({ "data" => {} })
      endpoint.order_detail(symbol: "BTCUSDT", order_id: "order-1")
    end
  end

  describe "#close_positions" do
    context "one_way_mode(hold_side 省略)の場合" do
      it "POST close-positions に symbol + productType のみ送信" do
        expect(rest_client).to receive(:request) do |method, path, **kwargs|
          expect(method).to eq(:post)
          expect(path).to eq("/api/v2/mix/order/close-positions")
          body = JSON.parse(kwargs[:body])
          expect(body).to include("symbol" => "BTCUSDT", "productType" => "usdt-futures")
          expect(body["holdSide"]).to be_nil
          { "data" => {} }
        end
        endpoint.close_positions(symbol: "BTCUSDT")
      end
    end

    context "hedge_mode で hold_side を指定する場合" do
      it "holdSide が含まれる" do
        expect(rest_client).to receive(:request) do |_method, _path, **kwargs|
          body = JSON.parse(kwargs[:body])
          expect(body["holdSide"]).to eq("long")
          { "data" => {} }
        end
        endpoint.close_positions(symbol: "BTCUSDT", hold_side: "long")
      end
    end
  end
end
