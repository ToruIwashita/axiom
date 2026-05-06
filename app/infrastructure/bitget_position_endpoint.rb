module Infrastructure
  # Bitget USDT-M 先物の Position / 設定 endpoint(設計書 05_§3.2 + 02_§4.2.5 反映)
  # bootstrap step 7(margin/position/asset/leverage 設定)+ step 11(reconciliation)で利用
  class BitgetPositionEndpoint
    PRODUCT_TYPE = "usdt-futures".freeze

    PATH_POSITION_ALL = "/api/v2/mix/position/all-position".freeze
    PATH_SET_MARGIN_MODE = "/api/v2/mix/account/set-margin-mode".freeze
    PATH_SET_POSITION_MODE = "/api/v2/mix/account/set-position-mode".freeze
    PATH_SET_ASSET_MODE = "/api/v2/mix/account/set-asset-mode".freeze
    PATH_SET_LEVERAGE = "/api/v2/mix/account/set-leverage".freeze

    private_constant :PRODUCT_TYPE,
                     :PATH_POSITION_ALL, :PATH_SET_MARGIN_MODE, :PATH_SET_POSITION_MODE,
                     :PATH_SET_ASSET_MODE, :PATH_SET_LEVERAGE

    # @param rest_client [Infrastructure::BitgetRestClient]
    def initialize(rest_client:)
      @rest_client = rest_client
    end

    # 保有ポジション一覧を取得する(reconciliation 用)
    #
    # @param margin_coin [String] 例: "USDT"
    # @param symbol [String, nil]
    # @return [Hash] レスポンスの "data"
    def position_all(margin_coin:, symbol: nil)
      params = { productType: PRODUCT_TYPE, marginCoin: margin_coin }
      params[:symbol] = symbol if symbol
      get(PATH_POSITION_ALL, params: params, endpoint_key: :position_all)
    end

    # margin_mode 設定(isolated / crossed)
    #
    # @param symbol [String]
    # @param margin_coin [String]
    # @param margin_mode [String] "isolated" / "crossed"
    # @return [Hash]
    def set_margin_mode(symbol:, margin_coin:, margin_mode:)
      body = {
        symbol: symbol,
        productType: PRODUCT_TYPE,
        marginCoin: margin_coin,
        marginMode: margin_mode
      }
      post(PATH_SET_MARGIN_MODE, body: body, endpoint_key: :set_margin_mode)
    end

    # position_mode 設定(one_way_mode / hedge_mode)
    #
    # @param position_mode [String] "one_way_mode" / "hedge_mode"
    # @return [Hash]
    def set_position_mode(position_mode:)
      body = {
        productType: PRODUCT_TYPE,
        posMode: position_mode
      }
      post(PATH_SET_POSITION_MODE, body: body, endpoint_key: :set_position_mode)
    end

    # asset_mode 設定(single / union)
    #
    # @param asset_mode [String] "single" / "union"
    # @return [Hash]
    def set_asset_mode(asset_mode:)
      body = {
        productType: PRODUCT_TYPE,
        assetMode: asset_mode
      }
      post(PATH_SET_ASSET_MODE, body: body, endpoint_key: :set_asset_mode)
    end

    # leverage 設定
    #
    # @param symbol [String]
    # @param margin_coin [String]
    # @param leverage [Integer]
    # @param hold_side [String, nil] hedge_mode 時のみ "long" / "short"
    # @return [Hash]
    def set_leverage(symbol:, margin_coin:, leverage:, hold_side: nil)
      body = {
        symbol: symbol,
        productType: PRODUCT_TYPE,
        marginCoin: margin_coin,
        leverage: leverage.to_s
      }
      body[:holdSide] = hold_side if hold_side
      post(PATH_SET_LEVERAGE, body: body, endpoint_key: :set_leverage)
    end

    private

    attr_reader :rest_client

    def get(path, params:, endpoint_key:)
      rest_client.request(:get, path, params: params, auth: true, endpoint_key: endpoint_key)
    end

    def post(path, body:, endpoint_key:)
      rest_client.request(:post, path, body: body.to_json, auth: true, endpoint_key: endpoint_key)
    end
  end
end
