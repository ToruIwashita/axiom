module Infrastructure
  # Bitget USDT-M 先物の Account / Fill 履歴 endpoint(設計書 05_§3.2 + 02_§4.2.6 反映)
  # bootstrap step 11 reconciliation で fill_history を使用 / 残高取得は account
  class BitgetAccountEndpoint
    PRODUCT_TYPE = "usdt-futures".freeze

    PATH_FILL_HISTORY = "/api/v2/mix/order/fill-history".freeze
    PATH_ACCOUNT = "/api/v2/mix/account/account".freeze

    private_constant :PRODUCT_TYPE, :PATH_FILL_HISTORY, :PATH_ACCOUNT

    # @param rest_client [Infrastructure::BitgetRestClient]
    def initialize(rest_client:)
      @rest_client = rest_client
    end

    # 約定履歴を取得する(reconciliation で WS fill 欠落分の補完に使用)
    #
    # @param start_time [Integer] Unix ms
    # @param end_time [Integer] Unix ms
    # @param symbol [String, nil]
    # @return [Hash] レスポンスの "data"
    def fill_history(start_time:, end_time:, symbol: nil)
      params = {
        productType: PRODUCT_TYPE,
        startTime: start_time,
        endTime: end_time
      }
      params[:symbol] = symbol if symbol
      get(PATH_FILL_HISTORY, params: params, endpoint_key: :fill_history)
    end

    # 口座情報(残高 / 利用可能 / 凍結 等)を取得する
    #
    # @param margin_coin [String] 例: "USDT"
    # @param symbol [String]
    # @return [Hash]
    def account(margin_coin:, symbol:)
      params = {
        symbol: symbol,
        productType: PRODUCT_TYPE,
        marginCoin: margin_coin
      }
      get(PATH_ACCOUNT, params: params, endpoint_key: :account)
    end

    private

    attr_reader :rest_client

    def get(path, params:, endpoint_key:)
      rest_client.request(:get, path, params: params, auth: true, endpoint_key: endpoint_key)
    end
  end
end
