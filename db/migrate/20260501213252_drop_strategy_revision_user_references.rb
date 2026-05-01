class DropStrategyRevisionUserReferences < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :strategy_revisions, column: :approved_by_id
    remove_foreign_key :strategy_revisions, column: :created_by_id
    remove_index :strategy_revisions, :approved_by_id
    remove_index :strategy_revisions, :created_by_id
    remove_column :strategy_revisions, :approved_by_id, :bigint
    remove_column :strategy_revisions, :created_by_id, :bigint, null: false
  end
end
