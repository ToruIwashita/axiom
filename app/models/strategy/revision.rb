module Strategy
  class Revision < ApplicationRecord
    self.table_name = "strategy_revisions"

    class LiveForbiddenInputError < StandardError; end

    STATUSES = %w[draft approved promoted deprecated archived].freeze
    AST_VALIDATION_STATUSES = %w[pending passed failed].freeze
    AI_FILTER_FAIL_SAFE_VALUES = %w[skip proceed].freeze
    IMMUTABLE_STATES = %w[approved promoted deprecated archived].freeze

    # state_draft! / state_approved! / state_promoted! / state_deprecated! / state_archived! が
    # AR 自動生成。状態のみを直接更新する内部用 bang メソッド(prefix: :state で衝突回避)。
    # 外部公開のドメインAPIは下記の approve! / promote! / deprecate! / archive! を使うこと。
    enum :status, STATUSES.index_with(&:itself), prefix: :state
    enum :ast_validation_status, AST_VALIDATION_STATUSES.index_with(&:itself), prefix: :ast_validation
    enum :ai_filter_fail_safe, AI_FILTER_FAIL_SAFE_VALUES.index_with(&:itself), prefix: :ai_filter_fail_safe

    belongs_to :strategy_definition,
               class_name: "Strategy::Definition",
               inverse_of: :revisions
    belongs_to :created_by, class_name: "User"
    belongs_to :approved_by, class_name: "User", optional: true

    validates :revision_number, presence: true,
                                uniqueness: { scope: :strategy_definition_id }
    validates :script_content, presence: true
    validates :script_entrypoint, presence: true
    validates :status, presence: true
    validates :ast_validation_status, presence: true
    validates :ai_filter_template_name, presence: true, if: :ai_filter_enabled?
    validates :ai_filter_fail_safe, presence: true, if: :ai_filter_enabled?

    validate :forbid_script_content_change_after_approved

    before_validation :compute_checksum

    # Revision を approved 状態に遷移する(公開ドメインAPI)
    #
    # @param approved_by [User] 承認者
    # @param approved_at [Time] 承認時刻
    # @return [Boolean] update! の結果
    # @note 内部実装は update! を使い AR enum 自動生成 state_approved! は呼ばない
    def approve!(approved_by:, approved_at: Time.current)
      update!(status: "approved", approved_by:, approved_at:)
    end

    # Revision を promoted 状態に遷移する(公開ドメインAPI)
    #
    # @param promoted_at [Time] 昇格時刻
    # @return [Boolean] update! の結果
    # @raise [LiveForbiddenInputError] uses_live_forbidden_input が true の場合
    # @note 内部実装は update! を使い AR enum 自動生成 state_promoted! は呼ばない
    def promote!(promoted_at: Time.current)
      raise LiveForbiddenInputError, "Cannot promote: revision uses live-forbidden inputs" if uses_live_forbidden_input?

      update!(status: "promoted", promoted_at:)
    end

    # Revision を deprecated 状態に遷移する(公開ドメインAPI)
    #
    # @param deprecated_at [Time] 非推奨化時刻
    # @return [Boolean] update! の結果
    def deprecate!(deprecated_at: Time.current)
      update!(status: "deprecated", deprecated_at:)
    end

    # Revision を archived 状態に遷移する(公開ドメインAPI)
    #
    # @param archived_at [Time] 廃止時刻
    # @return [Boolean] update! の結果
    def archive!(archived_at: Time.current)
      update!(status: "archived", archived_at:)
    end

    # Live 起動可能か判定する
    #
    # @return [Boolean] promoted か deprecated なら true
    def acceptable_for_live?
      state_promoted? || state_deprecated?
    end

    # Backtest 実行可能か判定する
    #
    # @return [Boolean] approved/promoted/deprecated/archived なら true
    def acceptable_for_backtest?
      state_approved? || state_promoted? || state_deprecated? || state_archived?
    end

    # Revision と strategy_definition の整合を検証する
    #
    # @param revision_id [Integer] Revision の ID
    # @param strategy_definition_id [Integer] 検証対象 Definition の ID
    # @return [Strategy::Revision] 整合確認済みの Revision
    # @raise [ActiveRecord::RecordNotFound] revision_id の Revision が存在しない場合
    # @raise [ArgumentError] revision の strategy_definition_id が一致しない場合
    def self.assert_strategy_definition_consistency!(revision_id, strategy_definition_id)
      revision = find(revision_id)
      unless revision.strategy_definition_id == strategy_definition_id
        raise ArgumentError,
              "strategy_definition_id mismatch: revision_id=#{revision_id} expects " \
              "strategy_definition_id=#{revision.strategy_definition_id} but got #{strategy_definition_id}"
      end

      revision
    end

    private

    def compute_checksum
      return if script_content.blank?

      self.script_checksum = Digest::SHA256.hexdigest(script_content)
    end

    # 重要5: approved 以降の Revision で script_content が変更された場合エラー
    # create時(persisted=false)は当然許可,update! のみ block する
    def forbid_script_content_change_after_approved
      return unless persisted?
      return unless script_content_changed?
      return unless IMMUTABLE_STATES.include?(status_was)

      errors.add(:script_content, "cannot be changed after revision is #{status_was}")
    end
  end
end
