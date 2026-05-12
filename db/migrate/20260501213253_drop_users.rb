class DropUsers < ActiveRecord::Migration[8.1]
  # Phase 3 末 multi-agent review #12 反映:
  # Phase 2 で User model 廃止に伴い users テーブルを削除した.既存データ消失済のため
  # rollback では schema を完全復元できない(元定義の `limit: 255` 等の差異もあり)ことから
  # **forward-only** とする.
  def up
    drop_table :users
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Phase 2 で User model 廃止と一体化した users テーブル削除のため rollback 不能 " \
          "(元 schema 復元用の create_users migration は別途 git 履歴を参照)."
  end
end
