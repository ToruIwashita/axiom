class BacktestExecutionJob < ApplicationJob
  queue_as :default

  # retry を完全禁止(設計書 05_§7.3、02_§4.6)
  sidekiq_options retry: false

  # Step 2-3 時点では BacktestingRunService からの enqueue 検証用 stub。
  # 02_§4.6 仕様に基づく実装は Step 2-5 で完成予定:
  # - run.state_pending? チェックで二重起動防止
  # - Backtesting::Run.start! → MarketDataRepository fetch → BacktestEngineService.run
  #   → persist_result → run.complete! の順で実行
  # - rescue: 重要 5 反映で run.reload.terminal? チェック後 run.fail!
  def perform(backtesting_run_id)
    raise NotImplementedError, "Implemented in Step 2-5"
  end
end
