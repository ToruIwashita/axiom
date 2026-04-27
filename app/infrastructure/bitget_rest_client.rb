module Infrastructure
  class BitgetRestClient
    DEFAULT_BASE_URL = "https://api.bitget.com".freeze
    DEFAULT_RETRY_OPTIONS = {
      max: 5,
      interval: 0.5,
      backoff_factor: 2,
      retry_statuses: [ 429 ],
      retry_exceptions: [ Faraday::TimeoutError, Faraday::ConnectionFailed ]
    }.freeze
    RETRYABLE_BITGET_CODES = %w[45001 40725 40808 40015].freeze
    SUCCESS_CODE = "00000".freeze

    # @param api_key [String] Bitget API key
    # @param secret_key [String] Bitget secret key(BitgetSigner にのみ渡す)
    # @param passphrase [String] Bitget API passphrase
    # @param paptrading_enabled [Boolean] Demo環境(`paptrading: 1` ヘッダ付与)
    # @param base_url [String] APIベースURL(既定 https://api.bitget.com)
    # @param signer [Infrastructure::BitgetSigner, nil] DI 用,nil なら自動生成
    # @param rate_limiter [Infrastructure::BitgetRateLimiter, nil] DI 用,nil なら自動生成
    # @param retry_options [Hash, nil] faraday-retry オプション上書き(テスト用に interval=0 等)
    def initialize(
      api_key:,
      secret_key:,
      passphrase:,
      paptrading_enabled: false,
      base_url: DEFAULT_BASE_URL,
      signer: nil,
      rate_limiter: nil,
      retry_options: nil
    )
      @api_key = api_key
      @passphrase = passphrase
      @paptrading_enabled = paptrading_enabled
      @signer = signer || Infrastructure::BitgetSigner.new(secret_key:)
      @rate_limiter = rate_limiter || Infrastructure::BitgetRateLimiter.new
      @retry_options = DEFAULT_RETRY_OPTIONS.merge(retry_options || {})
      @base_url = base_url
      @connection = build_connection
    end

    # Bitget V2 API へリクエストを発行する。
    #
    # @param method [Symbol] :get / :post / :put / :delete
    # @param path [String] APIパス(例: '/api/v2/mix/market/history-candles')
    # @param params [Hash] クエリパラメータ
    # @param body [Hash, nil] リクエストボディ(POST/PUT 時)
    # @param auth [Boolean] 認証ヘッダ付与の要否(既定 false)
    # @param endpoint_key [Symbol, nil] レート制御用エンドポイントキー(nil 時は :default)
    # @return [Hash] JSONパース済みレスポンスボディ(成功時 code='00000')
    # @raise [Infrastructure::BitgetApiError] code が '00000' 以外の場合
    def request(method, path, params: {}, body: nil, auth: false, endpoint_key: nil)
      retries = 0
      loop do
        rate_limiter.acquire(endpoint_key || :default)
        response =
          begin
            connection.run_request(method, path, body, nil) do |req|
              req.options.context = { auth_required: auth }
              req.params.update(params) if params.is_a?(Hash) && !params.empty?
            end
          rescue *retry_options[:retry_exceptions] => e
            raise if retries >= retry_options[:max]
            sleep_for_retry(retries)
            retries += 1
            next
          end

        if retryable?(response) && retries < retry_options[:max]
          sleep_for_retry(retries)
          retries += 1
          next
        end

        validate_response!(response)
        return response.body
      end
    end

    private

    attr_reader :api_key, :passphrase, :paptrading_enabled, :signer, :rate_limiter,
                :retry_options, :base_url, :connection

    def build_connection
      Faraday.new(url: base_url) do |conn|
        conn.request :json
        conn.use AuthenticationMiddleware, signer: signer, api_key: api_key, passphrase: passphrase
        conn.use PaptradingMiddleware, paptrading_enabled: paptrading_enabled
        conn.response :json, content_type: /\bjson$/
      end
    end

    def retryable?(response)
      return true if retry_options[:retry_statuses].include?(response.status)

      body = response.body
      body.is_a?(Hash) && RETRYABLE_BITGET_CODES.include?(body["code"])
    end

    def sleep_for_retry(retries)
      sleep(retry_options[:interval] * (retry_options[:backoff_factor]**retries))
    end

    def validate_response!(response)
      body = response.body
      return if body.is_a?(Hash) && body["code"] == SUCCESS_CODE

      code = body.is_a?(Hash) ? body["code"] : nil
      message = body.is_a?(Hash) ? body["msg"].to_s : "Unexpected response body: #{body.inspect}"
      raise Infrastructure::BitgetApiError.new(message, code: code, response_body: body)
    end

    class AuthenticationMiddleware < Faraday::Middleware
      def initialize(app, signer:, api_key:, passphrase:)
        super(app)
        @signer = signer
        @api_key = api_key
        @passphrase = passphrase
      end

      def on_request(env)
        context = env.request.context
        return unless context.is_a?(Hash) && context[:auth_required]

        timestamp_ms = (Time.now.to_f * 1000).to_i
        body_str = env.body.is_a?(String) ? env.body : env.body&.to_json
        signature = @signer.sign(
          timestamp: timestamp_ms,
          method: env.method.to_s,
          request_path: env.url.path,
          query_string: env.url.query,
          body: body_str
        )
        env.request_headers["ACCESS-KEY"] = @api_key
        env.request_headers["ACCESS-SIGN"] = signature
        env.request_headers["ACCESS-TIMESTAMP"] = timestamp_ms.to_s
        env.request_headers["ACCESS-PASSPHRASE"] = @passphrase
      end
    end
    private_constant :AuthenticationMiddleware

    class PaptradingMiddleware < Faraday::Middleware
      # Bitget の `/api/v2/public/*` パスは paptrading: 1 ヘッダ付与で 40404 Request URL NOT FOUND
      # を返すため,このプリフィックスではヘッダを付与しない(実機検証で確認済み)。
      PUBLIC_PATH_PREFIX = "/api/v2/public".freeze

      def initialize(app, paptrading_enabled:)
        super(app)
        @paptrading_enabled = paptrading_enabled
      end

      def on_request(env)
        return unless @paptrading_enabled
        return if env.url.path.start_with?(PUBLIC_PATH_PREFIX)
        env.request_headers["paptrading"] = "1"
      end
    end
    private_constant :PaptradingMiddleware
  end
end
