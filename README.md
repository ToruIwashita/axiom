# axiom

仮想通貨(Bitget USDT-M先物)のバックテストと自動取引を一気通貫で支援する Rails アプリケーション

## 前提環境

項目     | バージョン                       | 備考
:---     | :---                             | :---
OS       | macOS                            | 同一PC運用(開発/本番)
Ruby     | 3.4.8                            | asdf管理(`.tool-versions`に固定)
Rails    | 8.1.3                            | `Gemfile`に固定
MySQL    | 8.0(Docker)                     | `docker-compose.yml`の`mysql`サービス(host port 3307)
Redis    | 7-alpine(Docker)                | `docker-compose.yml`の`redis`サービス(host port 6379)
Docker   | Docker Compose v2                | `docker compose ...`
tmux     | 任意                             | 本番常駐運用で利用

## ディレクトリ構成(主要)

設計書 `03_全体アーキテクチャ初期設計.md §7.1 / §7.4` に準拠

```
app/
├── controllers/                         # HTTP I/F変換層
├── models/                              # ActiveRecord実装(7名前空間: Strategy::, Risk::, Backtesting::, LiveTrading::, Exchange::, MarketData::, Integration::)
├── domain/                              # 純粋Rubyドメイン層(Domain::XxxService / XxxValueObject 等, フラット配置)
├── application_services/                # ユースケース実行層(ApplicationServices::XxxService / XxxProcessManager 等, フラット配置)
├── infrastructure/                      # 外部I/Fクライアント層(Infrastructure::BitgetRestClient / ClaudeCodeInvoker 等, フラット配置)
│   └── claude_code_prompt_templates/    # AI呼び出し用プロンプトテンプレート(テキストファイル配置)
├── workers/                             # Sidekiq常駐ワーカー(親プロセス)
└── jobs/                                # ActiveJob/Sidekiq用ジョブ
```

zeitwerk名前空間設定の詳細は `config/application.rb` および `03_§7.4` 参照

## 開発環境セットアップ

### 1. 依存サービスの起動(MySQL / Redis)

```sh
docker compose up -d
```

確認:

```sh
docker compose ps
# axiom-mysql, axiom-redis-1 が Up であること
```

### 2. gem install

```sh
bundle install
```

### 3. credentials の確認

`config/master.key` がローカルに存在することを確認(本リポジトリには含まれない,`.gitignore`で除外)

credentials の内容を確認/編集する場合:

```sh
EDITOR=vim bin/rails credentials:edit
```

#### 必須セクション

```yaml
database:
  development:
    username: <MySQLユーザー名>
    password: <MySQLパスワード>
  test:
    username: <同上>
    password: <同上>
  production:
    username: <本番用,別管理>
    password: <本番用,別管理>

bitget:
  api_key: <Bitget API Key>
  secret_key: <Bitget Secret Key>
  passphrase: <Bitget API 作成時に設定したパスフレーズ>
  paptrading_enabled: true   # 開発時 Demo環境用,本番では false 必須
```

`paptrading_enabled` は Bitget Demo環境(模擬取引)を有効化するフラグ:

- **開発(development)**: `true` 必須(Demoキーで動作確認)
- **本番(production)**: `false` 必須(誤起動防止)
- **ENV 上書き**: `PAPTRADING_ENABLED=true|false` で開発時の一時切替可能(本番では設定しないこと)

### 4. データベース作成

```sh
bin/rails db:create
# axiom_development と axiom_test が作成される
# axiom_development は MYSQL_DATABASE で既に作成済の場合 "already exists" となる
```

将来 migration を追加した後は:

```sh
bin/rails db:migrate
```

### 5. 開発サーバ起動

開発時はそのまま起動:

```sh
bin/rails s
bundle exec sidekiq        # 別ターミナル
```

## 動作確認(Phase 0 受け入れ基準)

```sh
ruby -v                                      # ruby 3.4.8
bundle install                               # 例外なし
docker compose up -d                         # mysql/redis 起動
bin/rails runner "puts 'OK'"                 # OK
bin/rails db:create                          # 既存ならスキップ,axiom_test 作成
bundle exec rspec                            # 0 examples, 0 failures
bundle exec rubocop                          # no offenses detected
bundle exec sidekiq                          # 起動エラー無し(Ctrl+Cで停止)
```

## 本番運用(tmux常駐)

設計書 `03_§8.6` 準拠

開発と本番は**同一PC上で運用**する想定で,以下の方針で分離:

要素   | 開発                                  | 本番
:---   | :---                                  | :---
Rails  | ローカル起動(`bin/rails s`)          | tmux常駐(`RAILS_ENV=production bin/rails s`)
Sidekiq | ローカル起動(`bundle exec sidekiq`)  | tmux常駐(`RAILS_ENV=production bundle exec sidekiq`)
MySQL  | 同インスタンス,database `axiom_development` | 同インスタンス,database `axiom_production`
Redis  | 同コンテナ,DB番号 `0`                | 同コンテナ,DB番号 `1`

本番運用例:

```sh
tmux new -s axiom
# window 0
RAILS_ENV=production bin/rails s
# window 1
RAILS_ENV=production bundle exec sidekiq
```

### 本番投入の事前作業(初回のみ)

`config/environments/production.rb` で `config.require_master_key = true` を有効化しているため,master.key または `RAILS_MASTER_KEY` 環境変数が未設定の状態では production 起動できない。本番初回投入時は以下を実施する

1. `axiom_production` データベースを MySQL に作成

   ```sh
   mysql --no-defaults -u root -proot_password -h 127.0.0.1 -P 3307 \
     -e "CREATE DATABASE IF NOT EXISTS axiom_production CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci"
   ```

2. production credentials を編集して本番用 DB 認証情報を投入

   ```sh
   EDITOR=vim bin/rails credentials:edit -e production
   ```

   `database.production.{username,password}` に本番用 MySQL ユーザー/パスワードを設定

3. master.key または `config/credentials/production.key` を本番ホストに配置(`.gitignore` で除外済のためリポジトリには含まれない)

4. `RAILS_ENV=production bin/rails db:migrate` でスキーマ反映

5. tmux セッション内で Rails / Sidekiq を起動(本番運用例参照)

## 関連設計書

実装の詳細仕様は以下を参照(本リポジトリ外,ローカルのworks配下):

- `~/works/memolist/archived_tasks/2026-04-22_仮想通貨バックテスト・自動取引ツール実装/03_全体アーキテクチャ初期設計.md`
- `~/works/memolist/archived_tasks/2026-04-22_仮想通貨バックテスト・自動取引ツール実装/04_AIと決定論ロジックの棲み分け方針.md`
- `~/works/memolist/archived_tasks/2026-04-22_仮想通貨バックテスト・自動取引ツール実装/05_実装着手前の確定設計事項.md`

## ライセンス

本プロジェクトは個人開発・運用を想定しており現時点でライセンス未指定
