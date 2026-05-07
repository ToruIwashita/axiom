module Domain
  # Claude Code CLI を呼び出して AI フィルタ判断を取得する Domain サービス
  # (設計書 04_§修正2 + §9 / 02_§5.2.1 + レビュー重要 2 反映)
  #
  # ## 内部処理フロー
  # 1. template_repository で prompt を render(template + context → 文字列)
  # 2. ClaudeCodeInvoker で CLI 呼出 → stdout 取得(失敗時 nil)
  # 3. AiResponseValidatorService で JSON Schema 検証 → 通過なら Hash / 失敗なら nil
  # 4. Integration::AiInvocationLog.record! で記録(status: success/timeout/validation_failed)
  # 5. フォールバック分岐:
  #    - Invoker 失敗(nil)+ fail_safe="proceed" → context_type に応じた AI なし通過レスポンス返却
  #    - Invoker 失敗(nil)+ fail_safe="skip" → nil 返却(エントリー見送り)
  #    - Validator 失敗 → fail_safe に関わらず nil 返却(エントリー見送り固定 / 数値幻覚回避)
  #    - 成功 → 検証済 Hash 返却
  class AiFilterService
    PROCEED_DEFAULTS = {
      "entry_filter" => { "enter" => true, "reason" => "ai_filter_timeout_proceed_default" }.freeze,
      "position_sizing" => { "size_multiplier" => 1.0 }.freeze,
      "exception_close" => { "close" => false, "reason" => "ai_filter_timeout_proceed_default" }.freeze
    }.freeze

    private_constant :PROCEED_DEFAULTS

    # @param invoker [Infrastructure::ClaudeCodeInvoker]
    # @param validator [Domain::AiResponseValidatorService]
    # @param template_repository [#render] template + context を prompt 文字列に変換するオブジェクト
    # @param log_recorder [Integration::AiInvocationLog 相当] record! クラスメソッドを持つ
    # @param clock [#call] 現在時刻取得 Proc
    def initialize(invoker:, validator:, template_repository:, log_recorder:, clock: Time.method(:current))
      @invoker = invoker
      @validator = validator
      @template_repository = template_repository
      @log_recorder = log_recorder
      @clock = clock
    end

    # AI フィルタを呼び出す
    #
    # @param template [Symbol, String] template 識別子(template_repository が解決)
    # @param context [Hash] template に流し込む context 情報
    # @param context_type [String] "entry_filter" / "position_sizing" / "exception_close"
    # @param timeout_sec [Float] CLI タイムアウト秒数
    # @param fail_safe [String] "skip"(失敗時 nil)/ "proceed"(失敗時 AI なし通過)
    # @return [Hash, nil] 検証済レスポンス Hash / nil
    def call(template:, context:, context_type:, timeout_sec:, fail_safe:)
      start_at = clock.call
      prompt = template_repository.render(template: template, context: context)
      raw_response = invoker.invoke(prompt: prompt, timeout_sec: timeout_sec)
      latency_ms = elapsed_ms(start_at)

      if raw_response.nil?
        record_log(context_type:, prompt:, response: nil, latency_ms:, status: "timeout")
        return PROCEED_DEFAULTS[context_type] if fail_safe == "proceed"

        return nil
      end

      validated = validator.validate(raw_response: raw_response, context_type: context_type)

      if validated.nil?
        record_log(context_type:, prompt:, response: raw_response, latency_ms:, status: "validation_failed")
        return nil
      end

      record_log(context_type:, prompt:, response: raw_response, latency_ms:, status: "success")
      validated
    end

    private

    attr_reader :invoker, :validator, :template_repository, :log_recorder, :clock

    def elapsed_ms(start_at)
      ((clock.call - start_at) * 1000).to_i
    end

    def record_log(context_type:, prompt:, response:, latency_ms:, status:)
      log_recorder.record!(
        context_type: context_type,
        prompt: prompt,
        response: response,
        latency_ms: latency_ms,
        status: status
      )
    end
  end
end
