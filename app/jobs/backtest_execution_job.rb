class BacktestExecutionJob < ApplicationJob
  queue_as :default

  # retry を完全禁止(設計書 05_§7.3、02_§4.6)
  sidekiq_options retry: false

  # バックテストを 1 件実行する
  #
  # @param backtesting_run_id [Integer]
  # @return [void]
  # @note 02_§4.6 確定仕様 + 重要 5(rescue 内 reload.terminal? チェック)+
  #   Obs-C(再 raise 省略)+ Obs-D(failure_reason truncate)反映済
  def perform(backtesting_run_id)
    run = Backtesting::Run.find(backtesting_run_id)

    # 二重起動防止: pending 以外なら即 return(非 raise)
    return unless run.state_pending?

    repository = Infrastructure::MarketDataRepository.new
    engine = Domain::BacktestEngineService.new

    run.start!

    revision = run.strategy_revision
    policy = run.risk_policy
    range = run.period_from..run.period_to

    candles = fetch_candles(repository, run, range)
    funding_rates = run.include_funding_rate ? fetch_funding_rates(repository, run, range) : nil
    mark_candles = run.use_mark_basis ? fetch_mark_candles(repository, run, range) : nil
    spot_candles = run.use_spot_basis ? fetch_spot_candles(repository, run, range) : nil

    result = engine.run(
      strategy_revision: revision,
      risk_policy: policy,
      candles: candles,
      funding_rates: funding_rates,
      mark_candles: mark_candles,
      spot_candles: spot_candles,
      fee_rate: run.fee_rate,
      slippage_rate: run.slippage_rate
    )

    persist_result(run: run, result: result)
    run.complete!
  rescue StandardError => e
    # 重要 5: status race condition で run が既に terminal(cancelled 等)に
    # 遷移している場合,fail! は InvalidTransitionError を raise する。
    # 二次例外で Job が落ちるのを回避するため,terminal 確認を冒頭で実施し,
    # 既に終端なら何もせず return する。
    return if run.reload.terminal?

    run.fail!(failure_reason: "#{e.class}: #{e.message}")
    # Obs-C: 再 raise しない(retry: false で十分)
  end

  private

  def fetch_candles(repository, run, range)
    repository.fetch_futures_candles(run.symbol, run.granularity, range)
              .pluck(:ts, :open, :high, :low, :close, :base_volume, :quote_volume)
              .map do |row|
      {
        "ts" => row[0],
        "open" => row[1].to_s,
        "high" => row[2].to_s,
        "low" => row[3].to_s,
        "close" => row[4].to_s,
        "base_volume" => row[5]&.to_s,
        "quote_volume" => row[6]&.to_s
      }
    end
  end

  def fetch_funding_rates(repository, run, range)
    repository.fetch_funding_rates(run.symbol, range)
              .pluck(:funding_time, :funding_rate)
              .map { |ft, fr| { "funding_time" => ft, "funding_rate" => fr.to_s } }
  end

  def fetch_mark_candles(repository, run, range)
    repository.fetch_mark_candles(run.symbol, run.granularity, range)
              .pluck(:ts, :close)
              .map { |ts, c| { "ts" => ts, "close" => c.to_s } }
  end

  def fetch_spot_candles(repository, run, range)
    repository.fetch_spot_candles(run.symbol, run.granularity, range)
              .pluck(:ts, :close)
              .map { |ts, c| { "ts" => ts, "close" => c.to_s } }
  end

  # Phase 2.2 完了レビュー軽微 1 反映: 3 種別の DB 書き込みを単一 transaction で
  # ラップし,Metrics.create! 失敗時に Trades 含めて全ロールバックさせる.
  # これにより Run = failed / Trades = 残存 / Metrics = なし の不整合状態を回避する.
  # 重要 2(BacktestingRunService の transaction 削除)とは独立した文脈
  # (commit 後 enqueue 完了済の Job 内処理)であり矛盾しない.
  def persist_result(run:, result:)
    now = Time.current

    ActiveRecord::Base.transaction do
      if result[:trades].any?
        Backtesting::Trade.insert_all(
          result[:trades].map { |t| t.merge(backtesting_run_id: run.id, created_at: now, updated_at: now) }
        )
      end

      Backtesting::Metrics.create!(result[:metrics].to_h.merge(backtesting_run_id: run.id))

      if result[:equity_curve].any?
        Backtesting::EquityCurvePoint.insert_all(
          result[:equity_curve].map { |p| p.merge(backtesting_run_id: run.id, created_at: now, updated_at: now) }
        )
      end
    end
  end
end
