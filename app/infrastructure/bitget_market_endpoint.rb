module Infrastructure
  class BitgetMarketEndpoint
    FUTURES_PRODUCT_TYPE = "usdt-futures".freeze

    PATH_FUTURES_CANDLES = "/api/v2/mix/market/history-candles".freeze
    PATH_SPOT_CANDLES = "/api/v2/spot/market/history-candles".freeze
    PATH_MARK_CANDLES = "/api/v2/mix/market/history-mark-candles".freeze
    PATH_INDEX_CANDLES = "/api/v2/mix/market/history-index-candles".freeze
    PATH_FUNDING_RATE = "/api/v2/mix/market/history-fund-rate".freeze
    PATH_CONTRACTS = "/api/v2/mix/market/contracts".freeze

    private_constant :FUTURES_PRODUCT_TYPE,
                     :PATH_FUTURES_CANDLES, :PATH_SPOT_CANDLES,
                     :PATH_MARK_CANDLES, :PATH_INDEX_CANDLES,
                     :PATH_FUNDING_RATE, :PATH_CONTRACTS

    # @param rest_client [Infrastructure::BitgetRestClient] HTTP リクエスト発行用クライアント
    def initialize(rest_client:)
      @rest_client = rest_client
    end

    # USDT-M 先物の過去K線(history-candles)を取得する
    #
    # @param symbol [String] 例: 'BTCUSDT'
    # @param granularity [String] 先物表記(例: '1m'/'5m'/'15m'/'30m'/'1H'/'4H'/'1D')
    # @param start_time [Integer, nil] Unix ms(任意)
    # @param end_time [Integer, nil] Unix ms(任意,ページネーション用)
    # @param limit [Integer] 1リクエスト件数(既定 200,最大 200)
    # @return [Array<Hash>] [{ts:, open:, high:, low:, close:, base_volume:, quote_volume:, usdt_volume:}, ...]
    def history_futures_candles(symbol:, granularity:, start_time: nil, end_time: nil, limit: 200)
      params = build_futures_candle_params(symbol:, granularity:, start_time:, end_time:, limit:)
      response = rest_client.request(:get, PATH_FUTURES_CANDLES, params:, auth: false, endpoint_key: :history_futures_candles)
      response.fetch("data", []).map { |row| build_ohlcv_with_volume(row) }
    end

    # 現物の過去K線(history-candles)を取得する
    #
    # ⚠️ granularity は現物表記(例: '1min'/'5min'/'15min'/'30min'/'1H'/'4H'/'1D')に注意。
    # 先物の '1m' とは別表記なので呼び出し側で変換すること。
    #
    # @param symbol [String]
    # @param granularity [String] 現物表記
    # @param end_time [Integer, nil]
    # @param limit [Integer] 既定 100
    # @return [Array<Hash>] [{ts:, open:, high:, low:, close:, base_volume:, quote_volume:, usdt_volume:}, ...]
    def history_spot_candles(symbol:, granularity:, end_time: nil, limit: 100)
      params = { symbol:, granularity:, limit: }
      params[:endTime] = end_time if end_time
      response = rest_client.request(:get, PATH_SPOT_CANDLES, params:, auth: false, endpoint_key: :history_spot_candles)
      response.fetch("data", []).map { |row| build_ohlcv_with_volume(row) }
    end

    # USDT-M 先物の Mark Price K線(history-mark-candles)を取得する
    #
    # ⚠️ 1H足は **83日** までしか遡れないなど,granularity 別の遡及制限あり(09_§2.4)。
    #
    # @param symbol [String]
    # @param granularity [String]
    # @param start_time [Integer, nil]
    # @param end_time [Integer, nil]
    # @param limit [Integer] 既定 100
    # @return [Array<Hash>] [{ts:, open:, high:, low:, close:}, ...](出来高なし)
    def history_mark_candles(symbol:, granularity:, start_time: nil, end_time: nil, limit: 100)
      params = build_futures_candle_params(symbol:, granularity:, start_time:, end_time:, limit:)
      response = rest_client.request(:get, PATH_MARK_CANDLES, params:, auth: false, endpoint_key: :history_mark_candles)
      response.fetch("data", []).map { |row| build_ohlcv(row) }
    end

    # USDT-M 先物の Index Price K線(history-index-candles)を取得する
    #
    # ⚠️ Mark candle と同じ遡及制限あり。
    #
    # @param symbol [String]
    # @param granularity [String]
    # @param start_time [Integer, nil]
    # @param end_time [Integer, nil]
    # @param limit [Integer] 既定 100
    # @return [Array<Hash>] [{ts:, open:, high:, low:, close:}, ...](出来高なし)
    def history_index_candles(symbol:, granularity:, start_time: nil, end_time: nil, limit: 100)
      params = build_futures_candle_params(symbol:, granularity:, start_time:, end_time:, limit:)
      response = rest_client.request(:get, PATH_INDEX_CANDLES, params:, auth: false, endpoint_key: :history_index_candles)
      response.fetch("data", []).map { |row| build_ohlcv(row) }
    end

    # USDT-M 先物の Funding Rate 履歴(history-fund-rate)を取得する
    #
    # 他のエンドポイントと異なり pageSize/pageNo 方式のページネーションを使う(07_§4.6)。
    #
    # @param symbol [String]
    # @param page_size [Integer] 既定 100
    # @param page_no [Integer] 既定 1
    # @return [Array<Hash>] [{symbol:, funding_rate:, funding_time:}, ...]
    def history_funding_rate(symbol:, page_size: 100, page_no: 1)
      params = {
        symbol:,
        productType: FUTURES_PRODUCT_TYPE,
        pageSize: page_size,
        pageNo: page_no
      }
      response = rest_client.request(:get, PATH_FUNDING_RATE, params:, auth: false, endpoint_key: :history_funding_rate)
      response.fetch("data", []).map do |row|
        {
          symbol: row["symbol"],
          funding_rate: row["fundingRate"],
          funding_time: row["fundingTime"].to_i
        }
      end
    end

    # USDT-M 先物の symbol metadata(tick_size / price_place / volume_place 等)を取得する
    # (LiveTradingWorker bootstrap step 6 で利用)
    #
    # @param symbol [String] 例: 'BTCUSDT'
    # @return [Hash] { symbol:, price_place:, price_end_step:, tick_size:(BigDecimal),
    #                  volume_place:, size_multiplier:(BigDecimal), min_trade_num:(BigDecimal),
    #                  base_coin:, quote_coin: }
    # @raise [ArgumentError] symbol が見つからない場合
    def contract_metadata(symbol:)
      params = { productType: FUTURES_PRODUCT_TYPE, symbol: symbol }
      response = rest_client.request(:get, PATH_CONTRACTS, params:, auth: false, endpoint_key: :contract_metadata)
      data = response.fetch("data", [])
      raise ArgumentError, "contract_metadata: symbol not found (symbol=#{symbol})" if data.empty?

      build_contract_metadata(data.first)
    end

    private

    attr_reader :rest_client

    def build_futures_candle_params(symbol:, granularity:, start_time:, end_time:, limit:)
      params = {
        symbol:,
        productType: FUTURES_PRODUCT_TYPE,
        granularity:,
        limit:
      }
      params[:startTime] = start_time if start_time
      params[:endTime] = end_time if end_time
      params
    end

    def build_ohlcv_with_volume(row)
      {
        ts: row[0].to_i,
        open: row[1],
        high: row[2],
        low: row[3],
        close: row[4],
        base_volume: row[5],
        quote_volume: row[6],
        usdt_volume: row[7]
      }
    end

    def build_ohlcv(row)
      {
        ts: row[0].to_i,
        open: row[1],
        high: row[2],
        low: row[3],
        close: row[4]
      }
    end

    def build_contract_metadata(row)
      price_place = row["pricePlace"].to_i
      price_end_step = row["priceEndStep"].to_i
      tick_size = price_end_step.zero? ? BigDecimal("0") : BigDecimal(price_end_step) / (BigDecimal("10")**price_place)

      {
        symbol: row["symbol"],
        price_place: price_place,
        price_end_step: price_end_step,
        tick_size: tick_size,
        volume_place: row["volumePlace"].to_i,
        size_multiplier: BigDecimal(row.fetch("sizeMultiplier", "0").to_s),
        min_trade_num: BigDecimal(row.fetch("minTradeNum", "0").to_s),
        base_coin: row["baseCoin"],
        quote_coin: row["quoteCoin"]
      }
    end
  end
end
