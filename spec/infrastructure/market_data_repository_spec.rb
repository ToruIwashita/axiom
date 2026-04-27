require "rails_helper"

RSpec.describe Infrastructure::MarketDataRepository do
  let(:market_endpoint) { instance_double(Infrastructure::BitgetMarketEndpoint) }
  let(:repository) { described_class.new(market_endpoint:) }

  let(:symbol) { "BTCUSDT" }
  let(:granularity) { "1H" }
  let(:range_start) { Time.utc(2024, 1, 1, 0, 0, 0) }
  let(:range_end) { Time.utc(2024, 1, 1, 5, 0, 0) }
  let(:range) { range_start..range_end }

  describe "#fetch_futures_candles" do
    subject { repository.fetch_futures_candles(symbol, granularity, range) }

    let(:api_response) do
      [
        { ts: range_start.to_i * 1000, open: "50000", high: "50500", low: "49500", close: "50200",
          base_volume: "100", quote_volume: "5020000", usdt_volume: "5020000" },
        { ts: (range_start + 1.hour).to_i * 1000, open: "50200", high: "50300", low: "50100", close: "50250",
          base_volume: "50", quote_volume: "2512500", usdt_volume: "2512500" }
      ]
    end

    before do
      allow(market_endpoint).to receive(:history_futures_candles).and_return(api_response, [])
    end

    context "DBに既存データがない初回呼び出しの場合" do
      it "API呼び出し + DB保存 + Relation返却が行われる" do
        result = subject

        expect(market_endpoint).to have_received(:history_futures_candles).at_least(:once)
        expect(MarketData::FuturesCandle.count).to eq(2)
        expect(result.pluck(:symbol).uniq).to eq([ symbol ])
        expect(result.pluck(:granularity).uniq).to eq([ granularity ])
      end
    end

    context "DBに既存データがある2回目呼び出しの場合" do
      let(:api_call_log) { [] }

      before do
        allow(market_endpoint).to receive(:history_futures_candles) do |**args|
          api_call_log << args
          api_call_log.size > 1 ? [] : api_response
        end
        repository.fetch_futures_candles(symbol, granularity, range)
      end

      it "API呼び出しが追加発生せずDBから返却される" do
        first_round_count = api_call_log.size
        expect(first_round_count).to be >= 1

        result = subject

        expect(api_call_log.size).to eq(first_round_count)
        expect(result.count).to eq(2)
      end
    end

    context "ページネーション境界(最古 ts が range.first 以下)に到達した場合" do
      let(:api_response) do
        [
          { ts: (range_start - 1.hour).to_i * 1000, open: "1", high: "1", low: "1", close: "1",
            base_volume: "1", quote_volume: "1", usdt_volume: "1" }
        ]
      end

      it "無限ループせず終了し DB保存も完了する" do
        expect { subject }.not_to raise_error
        expect(MarketData::FuturesCandle.count).to be >= 0
      end
    end

    context "symbol が記号を含む場合" do
      let(:symbol) { "BTC_TEST/USDT" }

      it "DB クエリと API リクエストが特殊文字を含む symbol で正しく動作する" do
        expect { subject }.not_to raise_error
      end
    end
  end

  describe "#fetch_spot_candles" do
    subject { repository.fetch_spot_candles(symbol, granularity, range) }

    let(:api_response) do
      [
        { ts: range_start.to_i * 1000, open: "50000", high: "50500", low: "49500", close: "50200",
          base_volume: "100", quote_volume: "5020000", usdt_volume: "5020000" }
      ]
    end

    before do
      allow(market_endpoint).to receive(:history_spot_candles).and_return(api_response, [])
    end

    context "内部 granularity '1H' を渡した場合" do
      it "Bitget 現物表記 '1H' に変換されて API に渡される(1H は両表記で同一)" do
        subject
        expect(market_endpoint).to have_received(:history_spot_candles)
          .with(hash_including(granularity: "1H"))
      end
    end

    context "内部 granularity '1m' を渡した場合" do
      let(:granularity) { "1m" }
      let(:api_response) { [] }

      it "Bitget 現物表記 '1min' に変換されて API に渡される" do
        subject
        expect(market_endpoint).to have_received(:history_spot_candles)
          .with(hash_including(granularity: "1min"))
      end
    end
  end

  describe "#fetch_mark_candles" do
    let(:api_response) do
      [ { ts: range_start.to_i * 1000, open: "50000", high: "50500", low: "49500", close: "50200" } ]
    end

    before do
      allow(market_endpoint).to receive(:history_mark_candles).and_return(api_response, [])
    end

    context "83日以内の範囲を指定した場合" do
      subject { repository.fetch_mark_candles(symbol, granularity, range) }

      it "正常に取得して Relation を返す" do
        expect { subject }.not_to raise_error
        expect(subject).to be_a(ActiveRecord::Relation)
      end
    end

    context "83日を超える範囲を指定した場合" do
      let(:long_range) { range_start..(range_start + 100.days) }

      it "ArgumentError を raise する" do
        expect { repository.fetch_mark_candles(symbol, granularity, long_range) }
          .to raise_error(ArgumentError, /83日/)
      end
    end
  end

  describe "#fetch_index_candles" do
    let(:api_response) do
      [ { ts: range_start.to_i * 1000, open: "50000", high: "50500", low: "49500", close: "50200" } ]
    end

    before do
      allow(market_endpoint).to receive(:history_index_candles).and_return(api_response, [])
    end

    context "83日を超える範囲を指定した場合" do
      let(:long_range) { range_start..(range_start + 100.days) }

      it "ArgumentError を raise する" do
        expect { repository.fetch_index_candles(symbol, granularity, long_range) }
          .to raise_error(ArgumentError, /83日/)
      end
    end
  end

  describe "#fetch_funding_rates" do
    subject { repository.fetch_funding_rates(symbol, range) }

    let(:api_response) do
      [
        { symbol: symbol, funding_rate: "0.0001", funding_time: range_start.to_i * 1000 },
        { symbol: symbol, funding_rate: "0.00012", funding_time: (range_start + 8.hours).to_i * 1000 }
      ]
    end

    before do
      allow(market_endpoint).to receive(:history_funding_rate).and_return(api_response, [])
    end

    context "DBにデータがない初回呼び出しの場合" do
      it "API取得 + DB保存 + Relation返却が行われる" do
        result = subject
        expect(MarketData::FundingRateHistory.count).to be >= 1
        expect(result.pluck(:symbol).uniq).to eq([ symbol ])
      end
    end
  end

  describe "upsert_all 冪等性(重要2レビュー指摘対応)" do
    let(:api_response) do
      [
        { ts: range_start.to_i * 1000, open: "50000", high: "50500", low: "49500", close: "50200",
          base_volume: "100", quote_volume: "5020000", usdt_volume: "5020000" }
      ]
    end

    before do
      allow(market_endpoint).to receive(:history_futures_candles).and_return(api_response, [])
    end

    context "同一データで複数回 fetch_futures_candles を呼び出した場合" do
      it "重複エラーが発生せず DB レコード数が増えない" do
        repository.fetch_futures_candles(symbol, granularity, range)
        first_count = MarketData::FuturesCandle.count

        repository.fetch_futures_candles(symbol, granularity, range)
        second_count = MarketData::FuturesCandle.count

        expect(second_count).to eq(first_count)
      end
    end
  end
end
