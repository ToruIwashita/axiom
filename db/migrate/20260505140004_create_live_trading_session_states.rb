class CreateLiveTradingSessionStates < ActiveRecord::Migration[8.1]
  def change
    create_table :live_trading_session_states do |t|
      t.references :live_trading_session, null: false, foreign_key: true, index: { unique: true }
      t.json :state_data, null: false
      t.integer :lock_version, default: 0, null: false
      t.timestamps
    end
  end
end
