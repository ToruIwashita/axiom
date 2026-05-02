require "rails_helper"

RSpec.describe ApplicationServices::MarketDataSyncService do
  let(:repository) { instance_double(Infrastructure::MarketDataRepository) }
  let(:service) { described_class.new(repository: repository) }
  let(:symbol) { "BTCUSDT" }
  let(:granularity) { "1H" }
  let(:period_from) { Time.utc(2026, 1, 1) }
  let(:period_to) { Time.utc(2026, 1, 31) }
  let(:range) { period_from..period_to }

  describe "#sync" do
    subject do
      service.sync(
        symbol: symbol,
        data_types: data_types,
        granularity: granularity,
        period_from: period_from,
        period_to: period_to
      )
    end

    context "data_types: [futures_candles] を指定した場合" do
      let(:data_types) { %w[futures_candles] }
      let(:relation) { double("FuturesCandleRelation", size: 720) }

      before do
        allow(repository).to receive(:fetch_futures_candles).with(symbol, granularity, range).and_return(relation)
      end

      it "repository#fetch_futures_candles が呼ばれ件数 Hash を返す" do
        expect(subject).to eq("futures_candles" => 720)
      end
    end

    context "data_types: [funding_rates] を指定した場合" do
      let(:data_types) { %w[funding_rates] }
      let(:relation) { double("FundingRateRelation", size: 30) }

      before do
        allow(repository).to receive(:fetch_funding_rates).with(symbol, range).and_return(relation)
      end

      it "repository#fetch_funding_rates が呼ばれる(granularity 引数なし)" do
        expect(subject).to eq("funding_rates" => 30)
      end
    end

    context "data_types: 全 5 種類を一括指定した場合" do
      let(:data_types) { %w[futures_candles spot_candles mark_candles index_candles funding_rates] }

      before do
        allow(repository).to receive(:fetch_futures_candles).and_return(double(size: 1))
        allow(repository).to receive(:fetch_spot_candles).and_return(double(size: 2))
        allow(repository).to receive(:fetch_mark_candles).and_return(double(size: 3))
        allow(repository).to receive(:fetch_index_candles).and_return(double(size: 4))
        allow(repository).to receive(:fetch_funding_rates).and_return(double(size: 5))
      end

      it "全 data_type に対して repository が呼ばれ件数を返す" do
        expect(subject).to eq(
          "futures_candles" => 1,
          "spot_candles" => 2,
          "mark_candles" => 3,
          "index_candles" => 4,
          "funding_rates" => 5
        )
      end
    end

    context "未対応 data_type を含む場合" do
      let(:data_types) { %w[futures_candles unsupported_type] }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /unsupported data_types/)
      end
    end

    context "data_types が空配列の場合" do
      let(:data_types) { [] }

      it "空 Hash を返す(repository は呼ばれない)" do
        expect(subject).to eq({})
      end
    end
  end
end
