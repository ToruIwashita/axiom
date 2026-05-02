# 重要 2 対応(02_§0.4 / §4.4.1):
# ActiveJob の `enqueue_after_transaction_commit = :always` を有効化することで
# 「外側 transaction の commit 後に Redis enqueue」を強制する。
#
# これにより,BacktestingRunService#enqueue_backtest が
# `Backtesting::Run.create!` 直後に `BacktestExecutionJob.perform_later`
# を呼ぶ設計でも、Sidekiq worker が transaction commit より速く Job を
# pickup して `Backtesting::Run.find` で `RecordNotFound` を出す
# アンチパターンを排除する。
Rails.application.config.active_job.enqueue_after_transaction_commit = :always
