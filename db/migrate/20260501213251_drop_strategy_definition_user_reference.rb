class DropStrategyDefinitionUserReference < ActiveRecord::Migration[8.1]
  # Phase 3 末 multi-agent review #12 反映:
  # `remove_column ... null: false` で rollback すると既存行が存在する DB では
  # NULL 制約違反で失敗するため,本 migration は **forward-only** とする.
  # Phase 2 経緯: User model 廃止に伴い strategy_definitions.user_id を削除した(再追加予定なし).
  def up
    remove_foreign_key :strategy_definitions, :users
    remove_index :strategy_definitions, :user_id
    remove_column :strategy_definitions, :user_id
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Phase 2 で User model 廃止と一体化した user_id 削除のため rollback 不能."
  end
end
