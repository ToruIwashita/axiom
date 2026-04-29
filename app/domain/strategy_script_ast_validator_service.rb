require "set"

module Domain
  # AI生成戦略スクリプトを AST allowlist で静的検証するドメインサービス。
  #
  # `RubyVM::AbstractSyntaxTree.parse` で AST を取得し,自作 walker で禁止対象を検出する。
  # 禁止対象(05_§1.6.2)を1件でも検出すれば status :failed を返し,
  # 加えて `ctx.mark_basis` / `ctx.spot_basis` の呼び出しを検出した場合は
  # `uses_live_forbidden_input: true` を返す(05_§2.6)。
  #
  # 本サービスは Strategy::Revision の draft → approved 遷移前および
  # approved → promoted 遷移前に呼び出される。
  class StrategyScriptAstValidatorService
    # 検証結果。
    #
    # @!attribute status [r]
    #   @return [Symbol] :passed または :failed
    # @!attribute report [r]
    #   @return [String, nil] :failed 時の検出内容(複数違反は "; " 区切り)
    # @!attribute uses_live_forbidden_input [r]
    #   @return [Boolean] ctx.mark_basis / ctx.spot_basis を使う場合 true
    Result = Struct.new(:status, :report, :uses_live_forbidden_input, keyword_init: true) do
      def passed?
        status == :passed
      end

      def failed?
        status == :failed
      end
    end

    # 戦略スクリプトを AST allowlist に基づき検証する
    #
    # @param script_content [String] 戦略Rubyコード
    # @return [Result] status / report / uses_live_forbidden_input を含む検証結果
    def validate(script_content)
      ast =
        begin
          RubyVM::AbstractSyntaxTree.parse(script_content)
        rescue SyntaxError => e
          return Result.new(status: :failed, report: "syntax error: #{e.message}", uses_live_forbidden_input: false)
        end

      violations = []
      uses_live_forbidden_input = false

      walk(ast) do |node|
        violation = detect_violation(node)
        violations << violation if violation
        uses_live_forbidden_input = true if live_forbidden_input?(node)
      end

      if violations.empty?
        Result.new(status: :passed, report: nil, uses_live_forbidden_input: uses_live_forbidden_input)
      else
        Result.new(status: :failed, report: violations.uniq.join("; "), uses_live_forbidden_input: uses_live_forbidden_input)
      end
    end

    private

    DANGEROUS_METHOD_NAMES = %i[
      eval instance_eval module_eval class_eval binding
      __send__ send define_method method_missing
      exec system open
      require require_relative load autoload
    ].to_set.freeze
    private_constant :DANGEROUS_METHOD_NAMES

    DANGEROUS_TOP_CONSTS = %i[
      File Dir IO Pathname Process Thread Fiber Mutex
      Net Socket TCPSocket UDPSocket URI Faraday HTTP FFI Fiddle
    ].to_set.freeze
    private_constant :DANGEROUS_TOP_CONSTS

    DYNAMIC_CLASS_FACTORIES = %i[Class Module].to_set.freeze
    private_constant :DYNAMIC_CLASS_FACTORIES

    LIVE_FORBIDDEN_METHODS = %i[mark_basis spot_basis].to_set.freeze
    private_constant :LIVE_FORBIDDEN_METHODS

    def walk(node, &block)
      return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

      yield node
      node.children.each { |child| walk(child, &block) }
    end

    def detect_violation(node)
      case node.type
      when :FCALL, :VCALL
        method_name = node.children.first
        return "forbidden method: #{method_name}" if DANGEROUS_METHOD_NAMES.include?(method_name)
      when :CALL
        receiver, method_name, _args = node.children
        via_const = forbidden_call_via_const(receiver, method_name)
        return via_const if via_const
        return "forbidden method: #{method_name}" if DANGEROUS_METHOD_NAMES.include?(method_name)
      when :CONST
        const_name = node.children.first
        return "forbidden constant: #{const_name}" if %i[FFI Fiddle].include?(const_name)
      when :COLON2
        root = colon2_root_const(node)
        return "forbidden namespace: #{root}::*" if root && DANGEROUS_TOP_CONSTS.include?(root)
      when :XSTR, :DXSTR
        return "shell execution literal (backtick or %x{...})"
      end
      nil
    end

    def forbidden_call_via_const(receiver, method_name)
      return nil unless receiver.is_a?(RubyVM::AbstractSyntaxTree::Node)

      case receiver.type
      when :CONST
        const_name = receiver.children.first
        if DYNAMIC_CLASS_FACTORIES.include?(const_name) && method_name == :new
          "dynamic code generation: #{const_name}.new"
        elsif DANGEROUS_TOP_CONSTS.include?(const_name)
          "forbidden call via constant: #{const_name}.#{method_name}"
        end
      when :COLON2
        root = colon2_root_const(receiver)
        "forbidden call via namespace: #{root}::*##{method_name}" if root && DANGEROUS_TOP_CONSTS.include?(root)
      end
    end

    def colon2_root_const(node)
      return nil unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

      current = node
      current = current.children.first while current.is_a?(RubyVM::AbstractSyntaxTree::Node) && current.type == :COLON2
      return nil unless current.is_a?(RubyVM::AbstractSyntaxTree::Node) && current.type == :CONST

      current.children.first
    end

    def live_forbidden_input?(node)
      return false unless node.type == :CALL

      receiver, method_name, _args = node.children
      return false unless LIVE_FORBIDDEN_METHODS.include?(method_name)
      return false unless receiver.is_a?(RubyVM::AbstractSyntaxTree::Node)

      ctx_receiver?(receiver)
    end

    def ctx_receiver?(node)
      case node.type
      when :VCALL, :LVAR, :IVAR
        node.children.first == :ctx
      else
        false
      end
    end
  end
end
