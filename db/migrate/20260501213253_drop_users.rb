class DropUsers < ActiveRecord::Migration[8.1]
  def change
    drop_table :users do |t|
      t.string :email, null: false
      t.string :name, null: false
      t.timestamps
      t.index :email, unique: true
    end
  end
end
