module Infrastructure
  # Bitget USDT-M 先物の Order 関連 endpoint(発注 / キャンセル / 取得)
  # 設計書 05_§3.2 + 02_§4.2.4 反映
  # 全メソッド認証必須(auth: true)/ Phase 1.1 既実装の BitgetRestClient + BitgetSigner +
  # BitgetRateLimiter を活用
  class BitgetOrderEndpoint
    PRODUCT_TYPE = "usdt-futures".freeze

    PATH_PLACE_ORDER = "/api/v2/mix/order/place-order".freeze
    PATH_CANCEL_ORDER = "/api/v2/mix/order/cancel-order".freeze
    PATH_CANCEL_PLAN_ORDER = "/api/v2/mix/order/cancel-plan-order".freeze
    PATH_MODIFY_ORDER = "/api/v2/mix/order/modify-order".freeze
    PATH_ORDERS_PENDING = "/api/v2/mix/order/orders-pending".freeze
    PATH_ORDERS_PLAN_PENDING = "/api/v2/mix/order/orders-plan-pending".freeze
    PATH_ORDERS_PLAN_HISTORY = "/api/v2/mix/order/orders-plan-history".freeze
    PATH_PLAN_SUB_ORDER = "/api/v2/mix/order/plan-sub-order".freeze
    PATH_ORDER_DETAIL = "/api/v2/mix/order/detail".freeze
    PATH_CLOSE_POSITIONS = "/api/v2/mix/order/close-positions".freeze

    private_constant :PRODUCT_TYPE,
                     :PATH_PLACE_ORDER, :PATH_CANCEL_ORDER, :PATH_CANCEL_PLAN_ORDER, :PATH_MODIFY_ORDER,
                     :PATH_ORDERS_PENDING, :PATH_ORDERS_PLAN_PENDING, :PATH_ORDERS_PLAN_HISTORY,
                     :PATH_PLAN_SUB_ORDER, :PATH_ORDER_DETAIL, :PATH_CLOSE_POSITIONS

    # @param rest_client [Infrastructure::BitgetRestClient]
    def initialize(rest_client:)
      @rest_client = rest_client
    end

    # 通常注文を発注する
    # Phase 3.3 Step 0(Phase 3.2 引継 1 反映): marginMode / marginCoin を必須引数として受け取る
    # (Bitget V2 先物 place-order API 仕様で必須パラメータ)
    #
    # @param symbol [String] 例: "BTCUSDT"
    # @param margin_mode [String] "isolated" / "crossed"(必須)
    # @param margin_coin [String] 例: "USDT"(必須)
    # @param side [String] "buy" / "sell"
    # @param trade_side [String, nil] hedge_mode 時のみ "open" / "close"(one_way_mode 時は nil)
    # @param order_type [String] "limit" / "market"
    # @param size [String, BigDecimal] 数量
    # @param price [String, BigDecimal, nil] limit 注文時の価格(market 時は nil)
    # @param force [String] "gtc" / "ioc" / "fok" / "post_only"
    # @param reduce_only [String] "yes" / "no"
    # @param client_oid [String] 冪等性キー
    # @param preset_stop_surplus_price [String, nil] TP 委託価格(任意)
    # @param preset_stop_loss_price [String, nil] SL 委託価格(任意)
    # @return [Hash] レスポンスの "data"(orderId / clientOid 等)
    def place_order(symbol:, margin_mode:, margin_coin:, side:, order_type:, size:,
                    force:, reduce_only:, client_oid:,
                    trade_side: nil, price: nil,
                    preset_stop_surplus_price: nil, preset_stop_loss_price: nil)
      body = {
        symbol: symbol,
        productType: PRODUCT_TYPE,
        marginMode: margin_mode,
        marginCoin: margin_coin,
        side: side,
        orderType: order_type,
        size: size.to_s,
        force: force,
        reduceOnly: reduce_only,
        clientOid: client_oid
      }
      body[:tradeSide] = trade_side if trade_side
      body[:price] = price.to_s if price
      body[:presetStopSurplusPrice] = preset_stop_surplus_price.to_s if preset_stop_surplus_price
      body[:presetStopLossPrice] = preset_stop_loss_price.to_s if preset_stop_loss_price
      post(PATH_PLACE_ORDER, body: body, endpoint_key: :place_order)
    end

    # 通常注文をキャンセルする(order_id か client_oid のいずれか必須)
    #
    # @param symbol [String]
    # @param order_id [String, nil]
    # @param client_oid [String, nil]
    # @return [Hash]
    def cancel_order(symbol:, order_id: nil, client_oid: nil)
      raise ArgumentError, "order_id or client_oid is required" if order_id.nil? && client_oid.nil?

      body = {
        symbol: symbol,
        productType: PRODUCT_TYPE,
        orderId: order_id,
        clientOid: client_oid
      }.compact
      post(PATH_CANCEL_ORDER, body: body, endpoint_key: :cancel_order)
    end

    # 未トリガー Algo 注文をキャンセルする(order_id か client_oid のいずれか必須).
    # kill-switch cancel_only モードで未トリガー plan order を一括解除する用途.
    #
    # @param symbol [String]
    # @param order_id [String, nil]
    # @param client_oid [String, nil]
    # @return [Hash]
    def cancel_plan_order(symbol:, order_id: nil, client_oid: nil)
      if order_id.to_s.empty? && client_oid.to_s.empty?
        raise ArgumentError, "order_id or client_oid is required"
      end

      body = {
        symbol: symbol,
        productType: PRODUCT_TYPE,
        orderId: order_id,
        clientOid: client_oid
      }.compact
      post(PATH_CANCEL_PLAN_ORDER, body: body, endpoint_key: :cancel_plan_order)
    end

    # 通常注文を修正する
    #
    # @param symbol [String]
    # @param order_id [String]
    # @param new_price [String, BigDecimal, nil]
    # @param new_size [String, BigDecimal, nil]
    # @return [Hash]
    def modify_order(symbol:, order_id:, new_price: nil, new_size: nil)
      body = {
        symbol: symbol,
        productType: PRODUCT_TYPE,
        orderId: order_id,
        newPrice: new_price&.to_s,
        newSize: new_size&.to_s
      }.compact
      post(PATH_MODIFY_ORDER, body: body, endpoint_key: :modify_order)
    end

    # 未約定注文一覧を取得する(reconciliation 用)
    #
    # @param symbol [String, nil]
    # @return [Hash] レスポンスの "data"
    def orders_pending(symbol: nil)
      params = { productType: PRODUCT_TYPE }
      params[:symbol] = symbol if symbol
      get(PATH_ORDERS_PENDING, params: params, endpoint_key: :orders_pending)
    end

    # Bitget V2 で `orders-plan-pending` / `orders-plan-history` は planType を必須化.
    # 未指定だと "Parameter verification failed" / "The condition planType is not met" を返す.
    # demo 実機 probe で動作確認済の planType:
    # - normal_plan: 通常 trigger order
    # - profit_loss: TP/SL 統合 plan order
    # - track_plan: trailing stop
    PLAN_TYPES = %w[normal_plan profit_loss track_plan].freeze

    # 未トリガー Algo 注文一覧を取得する(reconciliation / kill_switch 用)
    #
    # @param plan_type [String] PLAN_TYPES 内の値.必須(V2 仕様)
    # @param symbol [String, nil]
    # @return [Hash]
    # @raise [ArgumentError] plan_type が PLAN_TYPES 外の場合
    def orders_plan_pending(plan_type:, symbol: nil)
      assert_valid_plan_type!(plan_type)
      params = { productType: PRODUCT_TYPE, planType: plan_type }
      params[:symbol] = symbol if symbol
      get(PATH_ORDERS_PLAN_PENDING, params: params, endpoint_key: :orders_plan_pending)
    end

    # Algo 注文履歴を取得する(reconciliation 用)
    #
    # @param start_time [Integer] Unix ms
    # @param end_time [Integer] Unix ms
    # @param plan_type [String] PLAN_TYPES 内の値.必須(V2 仕様)
    # @param symbol [String, nil]
    # @return [Hash]
    # @raise [ArgumentError] plan_type が PLAN_TYPES 外の場合
    def orders_plan_history(start_time:, end_time:, plan_type:, symbol: nil)
      assert_valid_plan_type!(plan_type)
      params = {
        productType: PRODUCT_TYPE,
        planType: plan_type,
        startTime: start_time,
        endTime: end_time
      }
      params[:symbol] = symbol if symbol
      get(PATH_ORDERS_PLAN_HISTORY, params: params, endpoint_key: :orders_plan_history)
    end

    # Algo 注文の trigger 後に発生したサブ注文(通常注文)詳細を取得する
    #
    # @param plan_id [String]
    # @return [Hash]
    def plan_sub_order(plan_id:)
      params = { productType: PRODUCT_TYPE, planId: plan_id }
      get(PATH_PLAN_SUB_ORDER, params: params, endpoint_key: :plan_sub_order)
    end

    # 通常注文の詳細を取得する
    #
    # @param symbol [String]
    # @param order_id [String]
    # @return [Hash]
    def order_detail(symbol:, order_id:)
      params = {
        productType: PRODUCT_TYPE,
        symbol: symbol,
        orderId: order_id
      }
      get(PATH_ORDER_DETAIL, params: params, endpoint_key: :order_detail)
    end

    # ポジションを成行クローズする(kill-switch 即時クローズ用)
    #
    # @param symbol [String]
    # @param hold_side [String, nil] "long" / "short"(hedge_mode 時のみ必要 / one_way_mode は nil)
    # @return [Hash]
    def close_positions(symbol:, hold_side: nil)
      body = {
        symbol: symbol,
        productType: PRODUCT_TYPE
      }
      body[:holdSide] = hold_side if hold_side
      post(PATH_CLOSE_POSITIONS, body: body, endpoint_key: :close_positions)
    end

    private

    attr_reader :rest_client

    def assert_valid_plan_type!(plan_type)
      return if PLAN_TYPES.include?(plan_type)
      raise ArgumentError, "plan_type must be one of #{PLAN_TYPES.inspect} but got #{plan_type.inspect}"
    end

    def get(path, params:, endpoint_key:)
      rest_client.request(:get, path, params: params, auth: true, endpoint_key: endpoint_key)
    end

    def post(path, body:, endpoint_key:)
      rest_client.request(:post, path, body: body.to_json, auth: true, endpoint_key: endpoint_key)
    end
  end
end
