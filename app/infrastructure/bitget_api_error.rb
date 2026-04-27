module Infrastructure
  class BitgetApiError < StandardError
    # @return [String, nil] Bitget レスポンスの code(例: "40001")
    attr_reader :code

    # @return [Hash, String, nil] Bitget レスポンスボディ全体(JSONパース後の Hash または生文字列)
    attr_reader :response_body

    # @param message [String] エラーメッセージ
    # @param code [String, nil] Bitget レスポンスの code
    # @param response_body [Hash, String, nil] Bitget レスポンスボディ
    def initialize(message, code: nil, response_body: nil)
      super(message)
      @code = code
      @response_body = response_body
    end
  end
end
