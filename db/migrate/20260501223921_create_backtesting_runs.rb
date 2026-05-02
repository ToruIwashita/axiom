class CreateBacktestingRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :backtesting_runs do |t|
      t.references :strategy_definition, null: false, foreign_key: true
      t.references :strategy_revision, null: false, foreign_key: true
      t.references :risk_policy, null: false, foreign_key: true
      t.string :symbol, limit: 32, null: false
      t.string :granularity, limit: 16, null: false
      t.datetime :period_from, null: false
      t.datetime :period_to, null: false
      t.decimal :fee_rate, precision: 8, scale: 6, null: false
      t.decimal :slippage_rate, precision: 8, scale: 6, null: false
      t.boolean :include_funding_rate, null: false, default: false
      t.boolean :use_mark_basis, null: false, default: false
      t.boolean :use_spot_basis, null: false, default: false
      t.string :status, limit: 32, null: false
      t.text :failure_reason
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps

      t.index :status
    end
  end
end
