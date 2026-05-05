module ApplicationServices
  # Strategy::Revision の CRUD + 状態遷移ユースケースを提供するアプリケーション層サービス
  #
  # トランザクション境界は各メソッド = 1 トランザクション(AR 暗黙 transaction)。
  # promote / deprecate / archive は Phase 3.0 で追加(本ファイルでは薄い Model ラッパー)。
  class StrategyRevisionService
    class ApprovalError < StandardError; end

    # @param ast_validator [Domain::StrategyScriptAstValidatorService]
    def initialize(ast_validator: Domain::StrategyScriptAstValidatorService.new)
      @ast_validator = ast_validator
    end

    # Draft Revision を新規作成する(AST 検証実施)
    #
    # @param definition_id [Integer]
    # @param script_content [String] 戦略 Ruby コード
    # @param script_entrypoint [String] eval 後にインスタンス化するクラス名
    # @param ai_filter_enabled [Boolean]
    # @param ai_filter_template_name [String, nil]
    # @param ai_filter_fail_safe [String, nil]
    # @param ai_filter_timeout_sec [Integer]
    # @param ai_sizing_enabled [Boolean]
    # @return [Strategy::Revision] status: :draft の Revision(AST 結果は ast_validation_status / ast_validation_report に記録)
    # @raise [ActiveRecord::RecordNotFound] definition_id の Definition が存在しない場合
    def create_draft(definition_id:, script_content:, script_entrypoint:,
                     ai_filter_enabled: false, ai_filter_template_name: nil,
                     ai_filter_fail_safe: nil, ai_filter_timeout_sec: 10,
                     ai_sizing_enabled: false)
      definition = Strategy::Definition.find(definition_id)
      next_revision_number = (definition.revisions.maximum(:revision_number) || 0) + 1

      ast_result = ast_validator.validate(script_content)

      Strategy::Revision.create!(
        strategy_definition: definition,
        revision_number: next_revision_number,
        script_content: script_content,
        script_entrypoint: script_entrypoint,
        status: "draft",
        ast_validation_status: ast_result.passed? ? "passed" : "failed",
        ast_validation_report: ast_result.report,
        uses_live_forbidden_input: ast_result.uses_live_forbidden_input || false,
        ai_filter_enabled: ai_filter_enabled,
        ai_filter_template_name: ai_filter_template_name,
        ai_filter_fail_safe: ai_filter_fail_safe,
        ai_filter_timeout_sec: ai_filter_timeout_sec,
        ai_sizing_enabled: ai_sizing_enabled
      )
    end

    # Draft Revision を承認する(AST 再検証 → approved 遷移)
    #
    # @param revision_id [Integer]
    # @return [Strategy::Revision] status: :approved に遷移済の Revision
    # @raise [ActiveRecord::RecordNotFound]
    # @raise [ApprovalError] draft 以外の Revision に呼ばれた場合 / AST 再検証 failed の場合
    def approve(revision_id:)
      revision = Strategy::Revision.find(revision_id)
      raise ApprovalError, "revision must be draft" unless revision.state_draft?

      ast_result = ast_validator.validate(revision.script_content)
      raise ApprovalError, "AST validation failed: #{ast_result.report}" unless ast_result.passed?

      revision.approve!
      revision
    end

    # Revision を本番昇格する(approved → promoted 遷移)
    # Phase 3.0 追加: ApplicationServices レベルの薄い Model ラッパー(整合検証は呼出側責務)
    #
    # @param revision_id [Integer]
    # @return [Strategy::Revision] status: :promoted に遷移済の Revision
    # @raise [ActiveRecord::RecordNotFound] revision_id の Revision が存在しない場合
    # @raise [Strategy::Revision::LiveForbiddenInputError] uses_live_forbidden_input == true の場合
    def promote(revision_id:)
      Strategy::Revision.find(revision_id).tap(&:promote!)
    end

    # Revision を取得する
    #
    # @param revision_id [Integer]
    # @return [Strategy::Revision]
    # @raise [ActiveRecord::RecordNotFound]
    def get(revision_id:)
      Strategy::Revision.find(revision_id)
    end

    # Definition 配下の Revision 一覧を revision_number 降順で返す
    #
    # @param definition_id [Integer]
    # @return [ActiveRecord::Relation<Strategy::Revision>]
    def list_by_definition(definition_id:)
      Strategy::Revision.where(strategy_definition_id: definition_id).order(revision_number: :desc)
    end

    private

    attr_reader :ast_validator
  end
end
