class CreateStrategyDefinitions < ActiveRecord::Migration[8.1]
  def change
    create_table :strategy_definitions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, limit: 255, null: false
      t.text :description
      t.string :market_type, limit: 32, null: false
      t.string :status, limit: 32, null: false
      t.timestamps
    end
    add_index :strategy_definitions, :status
  end
end
