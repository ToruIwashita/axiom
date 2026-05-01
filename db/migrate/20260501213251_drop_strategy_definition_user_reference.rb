class DropStrategyDefinitionUserReference < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :strategy_definitions, :users
    remove_index :strategy_definitions, :user_id
    remove_column :strategy_definitions, :user_id, :bigint, null: false
  end
end
