module Integration
  # Claude Code CLI 呼出のログ(設計書 04_§修正6 + 05_§11.5)
  # 7 種類の context_type x 4 status を記録し,フェイルセーフ階層の transparency を確保する
  class AiInvocationLog < ApplicationRecord
    self.table_name = "integration_ai_invocation_logs"

    CONTEXT_TYPES = %w[
      script_generation backtest_analysis strategy_improvement
      entry_filter position_sizing exception_close daily_review
    ].freeze
    STATUSES = %w[success timeout error validation_failed].freeze
    PROMPT_RESPONSE_MAX_LENGTH = 10_000

    private_constant :PROMPT_RESPONSE_MAX_LENGTH

    enum :context_type, CONTEXT_TYPES.index_with(&:itself), prefix: :context_type
    enum :status, STATUSES.index_with(&:itself), prefix: :state

    validates :context_type, presence: true
    validates :latency_ms, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :status, presence: true

    before_validation :truncate_prompt_and_response

    # AI 呼出ログを記録する
    # Phase 2.1 Obs-D の Backtesting::Run#failure_reason 10_000 文字 truncate と
    # 同パターン(レビュー軽微 3 反映: 推奨 → 確定)
    #
    # @param context_type [String] 7 種類の context_type のいずれか
    # @param prompt [String, nil] プロンプト本文(10_000 文字超は truncate)
    # @param response [String, nil] CLI レスポンス本文(10_000 文字超は truncate)
    # @param latency_ms [Integer] CLI 呼出経過時間(ms)
    # @param status [String] 4 status のいずれか
    # @return [Integration::AiInvocationLog] 作成されたログレコード
    def self.record!(context_type:, prompt:, response:, latency_ms:, status:)
      create!(
        context_type: context_type,
        prompt: prompt,
        response: response,
        latency_ms: latency_ms,
        status: status
      )
    end

    private

    def truncate_prompt_and_response
      self.prompt = prompt.to_s.truncate(PROMPT_RESPONSE_MAX_LENGTH) if prompt
      self.response = response.to_s.truncate(PROMPT_RESPONSE_MAX_LENGTH) if response
    end
  end
end
