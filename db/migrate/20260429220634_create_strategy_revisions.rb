class CreateStrategyRevisions < ActiveRecord::Migration[8.1]
  def change
    create_table :strategy_revisions do |t|
      t.references :strategy_definition, null: false, foreign_key: true
      t.integer :revision_number, null: false
      t.text :script_content, null: false
      t.string :script_checksum, limit: 64, null: false
      t.string :script_entrypoint, limit: 255, null: false
      t.string :status, limit: 32, null: false
      t.string :ast_validation_status, limit: 16, null: false
      t.text :ast_validation_report
      t.boolean :uses_live_forbidden_input, null: false, default: false
      t.boolean :ai_filter_enabled, null: false, default: false
      t.string :ai_filter_template_name, limit: 128
      t.boolean :ai_sizing_enabled, null: false, default: false
      t.integer :ai_filter_timeout_sec, default: 10
      t.string :ai_filter_fail_safe, limit: 16
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :approved_by, foreign_key: { to_table: :users }
      t.datetime :approved_at
      t.datetime :promoted_at
      t.datetime :deprecated_at
      t.datetime :archived_at
      t.timestamps
    end
    add_index :strategy_revisions, [ :strategy_definition_id, :revision_number ], unique: true
    add_index :strategy_revisions, :status
  end
end
