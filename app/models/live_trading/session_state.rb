module LiveTrading
  # ctx.state を永続化する 1 対 1 関連モデル(設計書 05_§2.7)
  #
  # ActiveRecord 標準の `lock_version` カラムによる楽観ロックを採用(レビュー重要 4 案 A)。
  # `update!` 時に自動で `WHERE lock_version = ?` 句が付与され,競合時は
  # `ActiveRecord::StaleObjectError` が raise される。
  # 子プロセス IPC で expected_version を渡す必要がある場合は `record.lock_version` を
  # 読み取って渡す(自動同期)。
  class SessionState < ApplicationRecord
    self.table_name = "live_trading_session_states"

    SUPPORTED_DIFF_OPS = %w[replace_all].freeze

    private_constant :SUPPORTED_DIFF_OPS

    belongs_to :live_trading_session, class_name: "LiveTrading::Session"

    validates :live_trading_session_id, uniqueness: true

    # JSON Patch 形式の差分を state_data に適用する(MVP は replace_all のみサポート)
    # Phase 2 引き継ぎ #19: 差分演算化(JSON Patch RFC 6902)は IPC payload サイズ問題化時に判断
    #
    # @param diff [Hash] `{ "op" => "replace_all", "value" => Hash }` の差分
    # @return [Boolean] update! の結果
    # @raise [ArgumentError] 未対応 op の場合(fail-fast)
    # @raise [ActiveRecord::StaleObjectError] 楽観ロック競合時
    def apply_diff!(diff:)
      op = diff["op"]
      raise ArgumentError, "unsupported diff op: #{op}" unless SUPPORTED_DIFF_OPS.include?(op)

      case op
      when "replace_all"
        update!(state_data: diff["value"])
      end
    end

    # state_data を完全置換する(callback 完了時の親プロセスからの全体同期用)
    #
    # @param new_state [Hash] 新しい state_data
    # @return [Boolean] update! の結果
    # @raise [ActiveRecord::StaleObjectError] 楽観ロック競合時
    def replace_all_state!(new_state:)
      update!(state_data: new_state)
    end
  end
end
