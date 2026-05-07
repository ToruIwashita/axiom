module Infrastructure
  # Claude Code CLI に渡す prompt テンプレートを提供する repository クラス
  # (設計書 04_§修正2 + 02_§5.2.1 の template_repository 役)
  #
  # ## 配置
  # template ファイルは `app/infrastructure/claude_code_prompt_templates/` 配下に
  # `{template}.txt` として配置(同名ディレクトリ内 .txt は zeitwerk 対象外)。
  #
  # ## 形式
  # template ファイルは単純なテキスト。`{{context_json}}` プレースホルダを
  # `context.to_json` 結果で置換する(複雑なテンプレートエンジンは導入しない)。
  class ClaudeCodePromptTemplates
    SUPPORTED_TEMPLATES = %w[entry_filter position_sizing exception_close].freeze
    CONTEXT_JSON_PLACEHOLDER = "{{context_json}}".freeze

    private_constant :SUPPORTED_TEMPLATES, :CONTEXT_JSON_PLACEHOLDER

    # template + context から prompt 文字列を構築する
    #
    # @param template [String, Symbol] "entry_filter" / "position_sizing" / "exception_close"
    # @param context [Hash] template に流し込む context 情報
    # @return [String] 置換済 prompt 文字列
    # @raise [ArgumentError] 未対応 template の場合
    def self.render(template:, context:)
      template_name = template.to_s
      unless SUPPORTED_TEMPLATES.include?(template_name)
        raise ArgumentError, "unsupported template: #{template.inspect} (supported: #{SUPPORTED_TEMPLATES})"
      end

      raw = File.read(template_path(template_name))
      raw.sub(CONTEXT_JSON_PLACEHOLDER, context.to_json)
    end

    def self.template_path(template_name)
      Rails.root.join("app/infrastructure/claude_code_prompt_templates", "#{template_name}.txt")
    end
    private_class_method :template_path
  end
end
