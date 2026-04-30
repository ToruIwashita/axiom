class CreateRiskPolicies < ActiveRecord::Migration[8.1]
  def change
    create_table :risk_policies do |t|
      t.string :name, null: false, limit: 100
      t.decimal :max_drawdown_pct, precision: 5, scale: 2, null: false
      t.integer :consecutive_loss_limit, null: false
      t.decimal :max_position_exposure_usdt, precision: 20, scale: 8, null: false
      t.integer :max_leverage, null: false
      t.integer :cooldown_minutes, null: false
      t.decimal :daily_loss_limit_usdt, precision: 20, scale: 8, null: false

      t.timestamps
    end

    add_index :risk_policies, :name, unique: true
  end
end
