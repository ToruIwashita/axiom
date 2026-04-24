# Sidekiq redis接続設定
#
# 設計書: 03_全体アーキテクチャ初期設計.md §8.6 運用構成
# - Redisは単一コンテナ(Dockerで起動), DB番号で環境分離
#   - development: DB 0
#   - production:  DB 1
#   - test:        DB 15(テスト専用)
redis_url = case Rails.env
            when "development" then "redis://127.0.0.1:6379/0"
            when "production"  then "redis://127.0.0.1:6379/1"
            when "test"        then "redis://127.0.0.1:6379/15"
            else raise "Unknown Rails.env: #{Rails.env}"
            end

Sidekiq.configure_server do |config|
  config.redis = { url: redis_url }
end

Sidekiq.configure_client do |config|
  config.redis = { url: redis_url }
end
