require "rails_helper"

RSpec.describe Infrastructure::BitgetMarketEndpoint do
  let(:rest_client) { instance_double(Infrastructure::BitgetRestClient) }
  let(:endpoint) { described_class.new(rest_client:) }

  describe "#history_futures_candles" do
    subject do
      endpoint.history_futures_candles(
        symbol: "BTCUSDT",
        granularity: "1H",
        start_time: 1_234_567_890_000,
        end_time: 1_234_567_999_000,
        limit: 200
      )
    end

    let(:bitget_response) do
      {
        "code" => "00000",
        "data" => [
          [ "1234567890123", "50000", "50500", "49500", "50200", "100", "5020000", "5020000" ],
          [ "1234567893723", "50200", "50300", "50100", "50250", "50", "2512500", "2512500" ]
        ]
      }
    end

    before do
      allow(rest_client).to receive(:request).and_return(bitget_response)
    end

    context "正常レスポンス(2件)を受信した場合" do
      it "正しいパスとパラメータで rest_client.request を呼び結果を構造化する" do
        result = subject

        expect(rest_client).to have_received(:request).with(
          :get,
          "/api/v2/mix/market/history-candles",
          params: {
            symbol: "BTCUSDT",
            productType: "usdt-futures",
            granularity: "1H",
            startTime: 1_234_567_890_000,
            endTime: 1_234_567_999_000,
            limit: 200
          },
          auth: false,
          endpoint_key: :history_futures_candles
        )

        expect(result).to eq([
          { ts: 1_234_567_890_123, open: "50000", high: "50500", low: "49500", close: "50200",
            base_volume: "100", quote_volume: "5020000", usdt_volume: "5020000" },
          { ts: 1_234_567_893_723, open: "50200", high: "50300", low: "50100", close: "50250",
            base_volume: "50", quote_volume: "2512500", usdt_volume: "2512500" }
        ])
      end
    end

    context "空配列レスポンスの場合" do
      let(:bitget_response) { { "code" => "00000", "data" => [] } }

      it "空配列を返す" do
        expect(subject).to eq([])
      end
    end
  end

  describe "#history_spot_candles" do
    subject do
      endpoint.history_spot_candles(
        symbol: "BTCUSDT",
        granularity: "1H",
        end_time: 1_234_567_999_000,
        limit: 100
      )
    end

    let(:bitget_response) do
      {
        "code" => "00000",
        "data" => [
          [ "1234567890123", "50000", "50500", "49500", "50200", "100", "5020000", "5020000" ]
        ]
      }
    end

    before do
      allow(rest_client).to receive(:request).and_return(bitget_response)
    end

    context "正常レスポンスを受信した場合" do
      it "現物用パスで rest_client.request を呼び結果を構造化する" do
        result = subject

        expect(rest_client).to have_received(:request).with(
          :get,
          "/api/v2/spot/market/history-candles",
          params: {
            symbol: "BTCUSDT",
            granularity: "1H",
            endTime: 1_234_567_999_000,
            limit: 100
          },
          auth: false,
          endpoint_key: :history_spot_candles
        )

        expect(result.first).to include(ts: 1_234_567_890_123, open: "50000")
      end
    end

    context "空配列レスポンスの場合" do
      let(:bitget_response) { { "code" => "00000", "data" => [] } }

      it "空配列を返す" do
        expect(subject).to eq([])
      end
    end
  end

  describe "#history_mark_candles" do
    subject do
      endpoint.history_mark_candles(
        symbol: "BTCUSDT",
        granularity: "1H",
        start_time: 1_234_567_890_000,
        end_time: 1_234_567_999_000,
        limit: 100
      )
    end

    let(:bitget_response) do
      {
        "code" => "00000",
        "data" => [
          [ "1234567890123", "50000", "50500", "49500", "50200" ]
        ]
      }
    end

    before do
      allow(rest_client).to receive(:request).and_return(bitget_response)
    end

    context "正常レスポンスを受信した場合" do
      it "出来高なしの mark candle 用パスで rest_client.request を呼び結果を構造化する" do
        result = subject

        expect(rest_client).to have_received(:request).with(
          :get,
          "/api/v2/mix/market/history-mark-candles",
          params: {
            symbol: "BTCUSDT",
            productType: "usdt-futures",
            granularity: "1H",
            startTime: 1_234_567_890_000,
            endTime: 1_234_567_999_000,
            limit: 100
          },
          auth: false,
          endpoint_key: :history_mark_candles
        )

        expect(result).to eq([
          { ts: 1_234_567_890_123, open: "50000", high: "50500", low: "49500", close: "50200" }
        ])
      end
    end

    context "空配列レスポンスの場合" do
      let(:bitget_response) { { "code" => "00000", "data" => [] } }

      it "空配列を返す" do
        expect(subject).to eq([])
      end
    end
  end

  describe "#history_index_candles" do
    subject do
      endpoint.history_index_candles(
        symbol: "BTCUSDT",
        granularity: "1H",
        start_time: 1_234_567_890_000,
        end_time: 1_234_567_999_000,
        limit: 100
      )
    end

    let(:bitget_response) do
      {
        "code" => "00000",
        "data" => [
          [ "1234567890123", "50000", "50500", "49500", "50200" ]
        ]
      }
    end

    before do
      allow(rest_client).to receive(:request).and_return(bitget_response)
    end

    context "正常レスポンスを受信した場合" do
      it "出来高なしの index candle 用パスで rest_client.request を呼び結果を構造化する" do
        result = subject

        expect(rest_client).to have_received(:request).with(
          :get,
          "/api/v2/mix/market/history-index-candles",
          params: {
            symbol: "BTCUSDT",
            productType: "usdt-futures",
            granularity: "1H",
            startTime: 1_234_567_890_000,
            endTime: 1_234_567_999_000,
            limit: 100
          },
          auth: false,
          endpoint_key: :history_index_candles
        )

        expect(result).to eq([
          { ts: 1_234_567_890_123, open: "50000", high: "50500", low: "49500", close: "50200" }
        ])
      end
    end

    context "空配列レスポンスの場合" do
      let(:bitget_response) { { "code" => "00000", "data" => [] } }

      it "空配列を返す" do
        expect(subject).to eq([])
      end
    end
  end

  describe "#history_funding_rate" do
    subject do
      endpoint.history_funding_rate(symbol: "BTCUSDT", page_size: 100, page_no: 1)
    end

    let(:bitget_response) do
      {
        "code" => "00000",
        "data" => [
          { "symbol" => "BTCUSDT", "fundingRate" => "0.0001", "fundingTime" => "1234567890123" },
          { "symbol" => "BTCUSDT", "fundingRate" => "0.0002", "fundingTime" => "1234539090123" }
        ]
      }
    end

    before do
      allow(rest_client).to receive(:request).and_return(bitget_response)
    end

    context "正常レスポンスを受信した場合" do
      it "pageNo/pageSize 方式で rest_client.request を呼び結果を構造化する" do
        result = subject

        expect(rest_client).to have_received(:request).with(
          :get,
          "/api/v2/mix/market/history-fund-rate",
          params: {
            symbol: "BTCUSDT",
            productType: "usdt-futures",
            pageSize: 100,
            pageNo: 1
          },
          auth: false,
          endpoint_key: :history_funding_rate
        )

        expect(result).to eq([
          { symbol: "BTCUSDT", funding_rate: "0.0001", funding_time: 1_234_567_890_123 },
          { symbol: "BTCUSDT", funding_rate: "0.0002", funding_time: 1_234_539_090_123 }
        ])
      end
    end

    context "空配列レスポンスの場合" do
      let(:bitget_response) { { "code" => "00000", "data" => [] } }

      it "空配列を返す" do
        expect(subject).to eq([])
      end
    end
  end
end
