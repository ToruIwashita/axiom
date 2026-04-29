module Infrastructure
  # 戦略実行子プロセスとの IPC 契約(JSON Schema 相当)を validate するクラス。
  #
  # 親→子 入力 schema(`§1.7.4.2`)と子→親 返却 schema(`§1.7.4.1`)を
  # 手書きの構造チェック(必須キー / 値域 / 型)で検証する。
  # 不正な schema は ArgumentError を raise し,呼び出し元
  # (`Infrastructure::StrategyRunnerChildSpawner`)が結果Hashへ反映する。
  class StrategyRunnerIpcProtocol
    SUPPORTED_SCHEMA_VERSION = "1.0".freeze
    SUPPORTED_CALLBACKS = %w[on_start on_tick on_order_event on_stop].freeze
    SUPPORTED_STATUSES = %w[ok timeout error].freeze
    REQUEST_REQUIRED_KEYS = %w[schema_version callback script_content script_checksum script_entrypoint ctx_input].freeze
    RESPONSE_REQUIRED_KEYS = %w[schema_version callback status order_intents logs errors strategy_state_diff].freeze

    # 親→子 IPC 入力 schema を検証する
    #
    # @param json [Hash] パース済み JSON Hash
    # @return [void]
    # @raise [ArgumentError] 必須キー欠落 / 型違反 / 値違反
    def validate_request(json)
      ensure_hash!(json, "request")
      ensure_required_keys!(json, REQUEST_REQUIRED_KEYS)
      ensure_schema_version!(json)
      ensure_callback!(json)
      ensure_string!(json, "script_content")
      ensure_string!(json, "script_checksum")
      ensure_string!(json, "script_entrypoint")
      ensure_hash_value!(json, "ctx_input")
    end

    # 子→親 IPC 返却 schema を検証する
    #
    # @param json [Hash] パース済み JSON Hash
    # @return [void]
    # @raise [ArgumentError] 必須キー欠落 / 型違反 / 値違反
    def validate_response(json)
      ensure_hash!(json, "response")
      ensure_required_keys!(json, RESPONSE_REQUIRED_KEYS)
      ensure_schema_version!(json)
      ensure_callback!(json)
      ensure_status!(json)
      ensure_array!(json, "order_intents")
      ensure_array!(json, "logs")
      ensure_array!(json, "errors")
      ensure_hash_value!(json, "strategy_state_diff")
    end

    private

    def ensure_hash!(json, label)
      raise ArgumentError, "#{label} must be a Hash" unless json.is_a?(Hash)
    end

    def ensure_required_keys!(json, required_keys)
      missing = required_keys - json.keys.map(&:to_s)
      return if missing.empty?

      raise ArgumentError, "missing required keys: #{missing.join(', ')}"
    end

    def ensure_schema_version!(json)
      return if json["schema_version"] == SUPPORTED_SCHEMA_VERSION

      raise ArgumentError, "unsupported schema_version: #{json['schema_version'].inspect}"
    end

    def ensure_callback!(json)
      return if SUPPORTED_CALLBACKS.include?(json["callback"])

      raise ArgumentError, "unsupported callback: #{json['callback'].inspect}"
    end

    def ensure_status!(json)
      return if SUPPORTED_STATUSES.include?(json["status"])

      raise ArgumentError, "unsupported status: #{json['status'].inspect}"
    end

    def ensure_string!(json, key)
      return if json[key].is_a?(String)

      raise ArgumentError, "#{key} must be a String, got #{json[key].class}"
    end

    def ensure_hash_value!(json, key)
      return if json[key].is_a?(Hash)

      raise ArgumentError, "#{key} must be a Hash, got #{json[key].class}"
    end

    def ensure_array!(json, key)
      return if json[key].is_a?(Array)

      raise ArgumentError, "#{key} must be an Array, got #{json[key].class}"
    end
  end
end
