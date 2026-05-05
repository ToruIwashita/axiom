class CreateIntegrationAiInvocationLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :integration_ai_invocation_logs do |t|
      t.string :context_type, limit: 32, null: false
      t.text :prompt
      t.text :response
      t.integer :latency_ms, null: false
      t.string :status, limit: 32, null: false
      t.timestamps

      t.index :context_type
      t.index :status
    end
  end
end
