module Domain
  # Claude Code CLI レスポンスの JSON Schema 検証(設計書 04_§修正6 + 02_§5.2.2)
  #
  # 3 形式の context_type 別 schema を自前手書き validator で検証する
  # (JSON Schema gem は採用しない / Phase 1.2 の StrategyRunnerIpcProtocol 同パターン)
  #
  # ## 形式
  # - entry_filter: { enter: bool, reason: string }
  # - position_sizing: { size_multiplier: number 0.5..1.5 }
  # - exception_close: { close: bool, reason: string }
  #
  # ## フェイルセーフ
  # JSON parse 失敗 / schema 違反 / 範囲外 / 未対応 context_type は全て nil 返却
  # (呼出側 AiFilterService が nil → エントリー見送り にフォールバック)
  class AiResponseValidatorService
    SIZE_MULTIPLIER_MIN = 0.5
    SIZE_MULTIPLIER_MAX = 1.5

    private_constant :SIZE_MULTIPLIER_MIN, :SIZE_MULTIPLIER_MAX

    # AI レスポンスを context_type 別に validate する
    #
    # @param raw_response [String, Hash] JSON 文字列または Hash
    # @param context_type [String] "entry_filter" / "position_sizing" / "exception_close"
    # @return [Hash, nil] 検証通過時は Hash,失敗 / 未対応時は nil
    def validate(raw_response:, context_type:)
      parsed = parse(raw_response)
      return nil if parsed.nil?

      case context_type
      when "entry_filter"     then validate_entry_filter(parsed)
      when "position_sizing"  then validate_position_sizing(parsed)
      when "exception_close"  then validate_exception_close(parsed)
      end
    end

    private

    def parse(raw)
      return raw if raw.is_a?(Hash)

      JSON.parse(raw.to_s)
    rescue JSON::ParserError
      nil
    end

    def validate_entry_filter(parsed)
      return nil unless parsed.is_a?(Hash)
      return nil unless boolean?(parsed["enter"]) && parsed["reason"].is_a?(String)

      parsed
    end

    def validate_position_sizing(parsed)
      return nil unless parsed.is_a?(Hash)

      multiplier = parsed["size_multiplier"]
      return nil unless multiplier.is_a?(Numeric)
      return nil unless multiplier >= SIZE_MULTIPLIER_MIN && multiplier <= SIZE_MULTIPLIER_MAX

      parsed
    end

    def validate_exception_close(parsed)
      return nil unless parsed.is_a?(Hash)
      return nil unless boolean?(parsed["close"]) && parsed["reason"].is_a?(String)

      parsed
    end

    def boolean?(value)
      value == true || value == false
    end
  end
end
