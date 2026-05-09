module Domain
  # log message / failure_reason から credentials を [FILTERED] に置換する Domain サービス.
  #
  # Phase 3.4-pre R-8 multi-agent review で Worker 責務肥大化(D-1)指摘を受け抽出した.
  # 元: LiveTradingWorker 内 sanitize_log_message + SECRET_PATTERN / SECRET_JSON_PATTERN.
  # 用途: failure_reason / data.inspect / e.message / その他 log 出力対象すべての sanitize.
  #
  # 対応 key 名(snake_case + camelCase / Bitget 仕様):
  #   - api_key / apiKey / secret_key / secretKey
  #   - passphrase / signature / sign
  #   - token / accessToken / access_token
  #   - access-key / access-sign / access-passphrase(Bitget HTTP header)
  #   - authorization / bearer / x-api-key / private_key
  #
  # 対応 2 形式:
  #   1. key=value 形式(`api_key=ABC123` など)→ `api_key=[FILTERED]`(区切り文字保持)
  #   2. JSON 形式(`"api_key": "ABC123"` など)→ value 部分のみ `[FILTERED]`(escape `\"` 対応)
  #
  # 誤マスク防止:
  #   - `=` / `: "..."` の context 必須(`passphrase は秘密です` のような通常テキストは不変)
  #   - URL parameter / 隣接記号(`&` / `]` / `"`)を終端文字に含めて誤拡張を防御
  module FailureReasonSanitizer
    SECRET_KEY_NAMES = %w[
      api_?key secret_?key passphrase signature sign
      token access_?token bearer authorization
      access-key access-sign access-passphrase
      private_?key x-api-key
    ].join("|").freeze
    # 終端文字: 空白・JSON / array 区切り(`,` `;` `}` `]`)・URL query 区切り(`&` `?` `#`)・
    # 連結代入(`=`)・引用符(`"`)。`=` を含めることで `api_key=A=B` 形式で次のトークンを呑み込まない.
    SECRET_PATTERN = /\b(#{SECRET_KEY_NAMES})(\s*=\s*)[^\s,;}&\]"=?#]+/i
    SECRET_JSON_PATTERN = /("(?:#{SECRET_KEY_NAMES})"\s*:\s*")(?:[^"\\]|\\.)*(")/i

    private_constant :SECRET_KEY_NAMES, :SECRET_PATTERN, :SECRET_JSON_PATTERN

    # 順序: JSON 形式を先に置換 → key=value 形式を後で置換(衝突回避).
    #
    # @param message [String, nil] sanitize 対象文字列(nil は空文字として扱う)
    # @return [String] credentials を [FILTERED] に置換した文字列
    def self.sanitize(message)
      message.to_s
             .gsub(SECRET_JSON_PATTERN, '\1[FILTERED]\2')
             .gsub(SECRET_PATTERN, '\1\2[FILTERED]')
    end
  end
end
