module ApplicationServices
  # MarketData の同期(Bitget API → DB upsert)ユースケースを提供する
  # アプリケーション層サービス
  #
  # 02_§4.5 の確定仕様に準拠. Infrastructure::MarketDataRepository に
  # 同期実処理を委譲する.
  class MarketDataSyncService
    DATA_TYPES = %w[futures_candles spot_candles mark_candles index_candles funding_rates].freeze
    private_constant :DATA_TYPES

    # @param repository [Infrastructure::MarketDataRepository]
    def initialize(repository: Infrastructure::MarketDataRepository.new)
      @repository = repository
    end

    # 指定された data_types を一括同期する
    #
    # @param symbol [String] 例: "BTCUSDT"
    # @param data_types [Array<String>] futures_candles / spot_candles /
    #   mark_candles / index_candles / funding_rates のサブセット
    # @param granularity [String, nil] candle 系の場合は必須(funding_rates のみなら nil 可)
    # @param period_from [Time]
    # @param period_to [Time]
    # @return [Hash{String => Integer}] data_type ごとの取得件数
    # @raise [ArgumentError] data_types に未対応の値を含む場合
    def sync(symbol:, data_types:, granularity: nil, period_from:, period_to:)
      invalid = data_types - DATA_TYPES
      raise ArgumentError, "unsupported data_types: #{invalid.inspect}" if invalid.any?

      range = period_from..period_to

      data_types.each_with_object({}) do |type, results|
        results[type] = case type
        when "futures_candles"
                          repository.fetch_futures_candles(symbol, granularity, range).size
        when "spot_candles"
                          repository.fetch_spot_candles(symbol, granularity, range).size
        when "mark_candles"
                          repository.fetch_mark_candles(symbol, granularity, range).size
        when "index_candles"
                          repository.fetch_index_candles(symbol, granularity, range).size
        when "funding_rates"
                          repository.fetch_funding_rates(symbol, range).size
        end
      end
    end

    private

    attr_reader :repository
  end
end
