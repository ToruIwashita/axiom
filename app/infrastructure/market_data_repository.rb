module Infrastructure
  class MarketDataRepository
    MARK_INDEX_MAX_DAYS = 83

    FUTURES_GRANULARITY_MAP = {
      "1m" => "1m", "3m" => "3m", "5m" => "5m", "15m" => "15m", "30m" => "30m",
      "1H" => "1H", "2H" => "2H", "4H" => "4H", "6H" => "6H", "8H" => "8H",
      "12H" => "12H", "1D" => "1D", "3D" => "3D", "1W" => "1W", "1M" => "1M"
    }.freeze

    SPOT_GRANULARITY_MAP = {
      "1m" => "1min", "5m" => "5min", "15m" => "15min", "30m" => "30min",
      "1H" => "1H", "4H" => "4H", "1D" => "1D", "1W" => "1W"
    }.freeze

    private_constant :MARK_INDEX_MAX_DAYS, :FUTURES_GRANULARITY_MAP, :SPOT_GRANULARITY_MAP

    # @param market_endpoint [Infrastructure::BitgetMarketEndpoint, nil] DI 用,nil なら自動構築
    # @param rest_client [Infrastructure::BitgetRestClient, nil] DI 用,nil なら credentials から自動構築
    def initialize(market_endpoint: nil, rest_client: nil)
      @market_endpoint_override = market_endpoint
      @rest_client_override = rest_client
    end

    # 先物OHLCV を取得する。DB キャッシュがあれば API を呼ばずDBから返却する。
    #
    # @param symbol [String] 例: 'BTCUSDT'
    # @param granularity [String] 内部表記(例: '1H')
    # @param range [Range<Time>] 取得対象の時間範囲(UTC)
    # @return [ActiveRecord::Relation<MarketData::FuturesCandle>]
    def fetch_futures_candles(symbol, granularity, range)
      ensure_candles_in_range(
        model: MarketData::FuturesCandle,
        symbol: symbol,
        granularity: granularity,
        range: range,
        bitget_granularity: convert_to_futures_granularity(granularity),
        api_method: :history_futures_candles,
        with_volume: true
      )
      MarketData::FuturesCandle.where(symbol: symbol, granularity: granularity, ts: range).order(:ts)
    end

    # 現物OHLCV を取得する。granularity は現物表記に内部変換される。
    #
    # @param symbol [String]
    # @param granularity [String] 内部表記(例: '1m','1H')
    # @param range [Range<Time>]
    # @return [ActiveRecord::Relation<MarketData::SpotCandle>]
    def fetch_spot_candles(symbol, granularity, range)
      ensure_candles_in_range(
        model: MarketData::SpotCandle,
        symbol: symbol,
        granularity: granularity,
        range: range,
        bitget_granularity: convert_to_spot_granularity(granularity),
        api_method: :history_spot_candles,
        with_volume: true,
        spot: true
      )
      MarketData::SpotCandle.where(symbol: symbol, granularity: granularity, ts: range).order(:ts)
    end

    # Mark Price K線を取得する。83日以内の範囲制限あり。
    #
    # @param symbol [String]
    # @param granularity [String]
    # @param range [Range<Time>]
    # @return [ActiveRecord::Relation<MarketData::MarkCandle>]
    # @raise [ArgumentError] range が 83 日を超える場合
    def fetch_mark_candles(symbol, granularity, range)
      validate_mark_index_range!(range)
      ensure_candles_in_range(
        model: MarketData::MarkCandle,
        symbol: symbol,
        granularity: granularity,
        range: range,
        bitget_granularity: convert_to_futures_granularity(granularity),
        api_method: :history_mark_candles,
        with_volume: false
      )
      MarketData::MarkCandle.where(symbol: symbol, granularity: granularity, ts: range).order(:ts)
    end

    # Index Price K線を取得する。83日以内の範囲制限あり。
    #
    # @param symbol [String]
    # @param granularity [String]
    # @param range [Range<Time>]
    # @return [ActiveRecord::Relation<MarketData::IndexCandle>]
    # @raise [ArgumentError] range が 83 日を超える場合
    def fetch_index_candles(symbol, granularity, range)
      validate_mark_index_range!(range)
      ensure_candles_in_range(
        model: MarketData::IndexCandle,
        symbol: symbol,
        granularity: granularity,
        range: range,
        bitget_granularity: convert_to_futures_granularity(granularity),
        api_method: :history_index_candles,
        with_volume: false
      )
      MarketData::IndexCandle.where(symbol: symbol, granularity: granularity, ts: range).order(:ts)
    end

    # Funding Rate 履歴を取得する。
    #
    # @param symbol [String]
    # @param range [Range<Time>]
    # @return [ActiveRecord::Relation<MarketData::FundingRateHistory>]
    def fetch_funding_rates(symbol, range)
      ensure_funding_rates_in_range(symbol, range)
      MarketData::FundingRateHistory.where(symbol: symbol, funding_time: range).order(:funding_time)
    end

    private

    def market_endpoint
      @market_endpoint_override || (@market_endpoint ||= build_default_market_endpoint)
    end

    def build_default_market_endpoint
      rest_client = @rest_client_override || build_default_rest_client
      Infrastructure::BitgetMarketEndpoint.new(rest_client: rest_client)
    end

    def build_default_rest_client
      Infrastructure::BitgetRestClient.new(
        api_key: bitget_credential(:api_key),
        secret_key: bitget_credential(:secret_key),
        passphrase: bitget_credential(:passphrase),
        paptrading_enabled: paptrading_enabled
      )
    end

    def bitget_credential(key)
      Rails.application.credentials.dig(:bitget, key)
    end

    def paptrading_enabled
      return ENV["PAPTRADING_ENABLED"] == "true" if ENV.key?("PAPTRADING_ENABLED")
      !!bitget_credential(:paptrading_enabled)
    end

    def validate_mark_index_range!(range)
      span_days = (range.last - range.first) / 86_400.0
      return if span_days <= MARK_INDEX_MAX_DAYS
      raise ArgumentError,
            "Mark/Index Candleの取得範囲は#{MARK_INDEX_MAX_DAYS}日以内である必要があります(指定: #{span_days.round(2)}日)"
    end

    def convert_to_futures_granularity(granularity)
      FUTURES_GRANULARITY_MAP.fetch(granularity, granularity)
    end

    def convert_to_spot_granularity(granularity)
      SPOT_GRANULARITY_MAP.fetch(granularity) do
        raise ArgumentError, "Spot granularity '#{granularity}' is not supported"
      end
    end

    def ensure_candles_in_range(model:, symbol:, granularity:, range:, bitget_granularity:, api_method:, with_volume:, spot: false)
      return if model.where(symbol: symbol, granularity: granularity, ts: range).exists?

      start_ms = (range.first.to_f * 1000).to_i
      end_ms = (range.last.to_f * 1000).to_i

      loop do
        rows = invoke_candle_api(api_method:, symbol:, bitget_granularity:, start_ms:, end_ms:, spot:)
        break if rows.empty?

        persist_candles(model, symbol, granularity, rows, with_volume: with_volume)

        oldest_ts = rows.last[:ts]
        break if oldest_ts <= start_ms
        end_ms = oldest_ts - 1
      end
    end

    def invoke_candle_api(api_method:, symbol:, bitget_granularity:, start_ms:, end_ms:, spot:)
      if spot
        market_endpoint.public_send(api_method, symbol: symbol, granularity: bitget_granularity, end_time: end_ms, limit: 100)
      else
        market_endpoint.public_send(api_method, symbol: symbol, granularity: bitget_granularity, start_time: start_ms, end_time: end_ms, limit: 200)
      end
    end

    def persist_candles(model, symbol, granularity, rows, with_volume:)
      records = rows.map do |row|
        record = {
          symbol: symbol,
          granularity: granularity,
          ts: Time.at(row[:ts] / 1000.0).utc,
          open: row[:open],
          high: row[:high],
          low: row[:low],
          close: row[:close],
          created_at: Time.current
        }
        if with_volume
          record[:base_volume] = row[:base_volume]
          record[:quote_volume] = row[:quote_volume]
        end
        record
      end
      # MySQL adapter は :unique_by 引数を受け付けない(MySQL は ON DUPLICATE KEY UPDATE で
      # 全ユニーク索引を自動考慮するため引数省略が正解)。本テーブルのユニーク索引は
      # (symbol, granularity, ts) のみなので意図通り動作する。
      model.upsert_all(records)
    end

    def ensure_funding_rates_in_range(symbol, range)
      return if MarketData::FundingRateHistory.where(symbol: symbol, funding_time: range).exists?

      start_ms = (range.first.to_f * 1000).to_i
      end_ms = (range.last.to_f * 1000).to_i
      page_no = 1

      loop do
        rows = market_endpoint.history_funding_rate(symbol: symbol, page_size: 100, page_no: page_no)
        break if rows.empty?

        in_range = rows.select { |row| row[:funding_time].between?(start_ms, end_ms) }
        persist_funding_rates(in_range) if in_range.any?

        oldest_in_page = rows.last[:funding_time]
        break if oldest_in_page <= start_ms

        page_no += 1
      end
    end

    def persist_funding_rates(rows)
      records = rows.map do |row|
        {
          symbol: row[:symbol],
          funding_time: Time.at(row[:funding_time] / 1000.0).utc,
          funding_rate: row[:funding_rate],
          created_at: Time.current
        }
      end
      # MySQL は :unique_by 非サポートのため省略(ユニーク索引 (symbol, funding_time) で自動マッチ)
      MarketData::FundingRateHistory.upsert_all(records)
    end
  end
end
