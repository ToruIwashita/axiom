module Infrastructure
  class BitgetSigner
    # @param secret_key [String] Bitget API secret key(Demo環境または本番環境)
    def initialize(secret_key:)
      @secret_key = secret_key
    end

    # Bitget V2 API リクエスト用の HMAC-SHA256 + Base64 署名を生成する
    # preHash 仕様: timestamp + method.upcase + request_path + (?query_string) + body
    #
    # @param timestamp [Integer] Unix epoch ミリ秒(13桁)
    # @param method [String] HTTPメソッド(例: 'GET' / 'POST'。小文字でも可,内部で upcase)
    # @param request_path [String] APIパス(例: '/api/v2/mix/market/history-candles')
    # @param query_string [String, nil] URLクエリ文字列(nil/空文字は ?無しで扱う)
    # @param body [String, nil] リクエストボディ(POST時の JSON文字列。nilは空扱い)
    # @return [String] Base64エンコード済み HMAC-SHA256 署名
    def sign(timestamp:, method:, request_path:, query_string: nil, body: nil)
      pre_hash = build_pre_hash(timestamp:, method:, request_path:, query_string:, body:)
      digest = OpenSSL::HMAC.digest("SHA256", secret_key, pre_hash)
      Base64.strict_encode64(digest)
    end

    private

    attr_reader :secret_key

    def build_pre_hash(timestamp:, method:, request_path:, query_string:, body:)
      query_part = query_string.nil? || query_string.empty? ? "" : "?#{query_string}"
      body_part = body || ""
      "#{timestamp}#{method.upcase}#{request_path}#{query_part}#{body_part}"
    end
  end
end
