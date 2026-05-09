module Domain
  # bootstrap step 11 / WS reconnect 後 / algo anomaly 検出時の reconciliation(REST 突合)を担う Domain サービス.
  #
  # Phase 3.4-pre R-8-6 で Worker 責務肥大化解消のため抽出した.
  # 元: LiveTradingWorker 内 run_reconciliation / run_reconciliation_after_reconnect /
  #     evaluate_reconciliation_outcome / reconcile_orders_pending / reconcile_orders_plan_pending /
  #     reconcile_orders_plan_history / reconcile_position_all / reconcile_fill_history.
  #
  # 責務:
  #   - bootstrap 時の reconciliation(state 遷移 starting → reconciling + 5 件 REST 突合 + 結果集約)
  #   - reconnect / algo anomaly 検出後の reconciliation(状態遷移なし / 5 件 REST のみ)
  #   - 結果集約: 全成功 / 部分失敗(warn 続行) / 全失敗(raise) の 3 経路振り分け
  #
  # MVP 範囲(5 件):
  #   - orders_pending: 未約定通常注文
  #   - orders_plan_pending: 未起動 plan order
  #   - orders_plan_history: 履歴 plan order(直近 24h)
  #   - position_all: 全 position
  #   - fill_history: 約定履歴(直近 24h / WS fill push 欠落分の補完)
  #
  # 各 reconcile_* の戻り値 contract:
  #   - 成功時: API レスポンス Hash
  #   - 失敗時: nil(rescue で warn 落としつつ後続 reconcile を継続させる部分復旧志向)
  class ReconciliationCoordinator
    FAILURE_SENTINELS = [ nil, false, :failed ].freeze
    PLAN_HISTORY_LOOKBACK_MS = 24 * 60 * 60 * 1000

    private_constant :FAILURE_SENTINELS, :PLAN_HISTORY_LOOKBACK_MS

    # 注: 各 endpoint は Bitget 固有のメソッド名(orders_pending / orders_plan_pending / position_all 等)に
    # 直接依存している. 将来 exchange 切替を検討する場合は Coordinator も改修対象になるため,
    # その時点で `Domain::ReconciliationGateway` 等の抽象を別途検討する.
    #
    # @param order_endpoint [Infrastructure::BitgetOrderEndpoint] orders_pending / orders_plan_pending / orders_plan_history
    # @param position_endpoint [Infrastructure::BitgetPositionEndpoint] position_all
    # @param account_endpoint [Infrastructure::BitgetAccountEndpoint] fill_history
    # @param logger [Logger] 部分失敗 warn / 各 reconcile 失敗 warn の出力先
    def initialize(order_endpoint:, position_endpoint:, account_endpoint:, logger: Rails.logger)
      @order_endpoint = order_endpoint
      @position_endpoint = position_endpoint
      @account_endpoint = account_endpoint
      @logger = logger
    end

    # bootstrap step 11: starts → reconciling 遷移 + 5 件 REST 突合 + 結果集約.
    #
    # @param session [LiveTrading::Session]
    # @return [void]
    # @raise [StandardError] 全 reconcile_* 失敗時(bootstrap 中断 → cleanup_on_failure 経由)
    def run_for_bootstrap(session)
      session.start_reconciling!

      results = collect_reconciliation_results(session)
      evaluate_outcome(results)
    end

    # WS reconnect / algo anomaly 検出後の reconciliation 再実行.
    # bootstrap step 11 と異なり session 状態遷移は行わず結果集約も行わない
    # (running 状態のまま 5 件 REST 突合のみ).
    #
    # @param session [LiveTrading::Session]
    # @return [void]
    def run_after_reconnect(session)
      collect_reconciliation_results(session)
      nil
    end

    private

    attr_reader :order_endpoint, :position_endpoint, :account_endpoint, :logger

    def collect_reconciliation_results(session)
      {
        orders_pending: reconcile_orders_pending(session),
        orders_plan_pending: reconcile_orders_plan_pending(session),
        orders_plan_history: reconcile_orders_plan_history(session),
        position_all: reconcile_position_all(session),
        fill_history: reconcile_fill_history(session)
      }
    end

    # 結果集約: 全成功 / 部分失敗 / 全失敗の 3 経路に振り分ける.
    # - 全成功: 何もせず続行
    # - 部分失敗: logger.warn でアラート + 続行(MVP 暫定 / 04_運用ガイド §6.2-2 で目視確認)
    # - 全失敗: raise → bootstrap_session の rescue → cleanup_on_failure → mark_failed_to_start!
    #
    # R-8-3 #C-4 反映: failed 判定を明示化(nil / false / 例外 sentinel `:failed` を失敗扱い).
    # 将来 false / Symbol 戻り値に変わっても silent 見逃しを防ぐ.
    def evaluate_outcome(results)
      raise ArgumentError, "results must not be empty" if results.empty?

      failed = results.select { |_, v| FAILURE_SENTINELS.include?(v) }.keys
      total = results.size
      failed_count = failed.size

      return if failed_count.zero?

      if failed_count == total
        raise StandardError, "reconciliation all failed: #{failed.inspect}"
      else
        logger.warn(
          "[ReconciliationCoordinator] reconciliation partially failed " \
          "(#{failed_count}/#{total}): failed=#{failed.inspect}"
        )
      end
    end

    def reconcile_orders_pending(session)
      response = order_endpoint.orders_pending(symbol: session.symbol)
      # TODO(後続 phase): response["data"] から Exchange::Order upsert
      response
    rescue StandardError => e
      log_reconcile_failure(:reconcile_orders_pending, e)
      nil
    end

    def reconcile_orders_plan_pending(session)
      response = order_endpoint.orders_plan_pending(symbol: session.symbol)
      # TODO(後続 phase): response["data"] から Exchange::AlgoOrder upsert
      #   + 各 plan_id について order_endpoint.plan_sub_order(plan_id:) を呼んで sub-order を反映
      response
    rescue StandardError => e
      log_reconcile_failure(:reconcile_orders_plan_pending, e)
      nil
    end

    # 直近 24h の履歴 plan order を取得する(MVP デフォルト範囲 / 設計書明示なしのため固定値).
    def reconcile_orders_plan_history(session)
      end_time = (Time.current.to_f * 1000).to_i
      start_time = end_time - PLAN_HISTORY_LOOKBACK_MS

      response = order_endpoint.orders_plan_history(
        symbol: session.symbol, start_time: start_time, end_time: end_time
      )
      # TODO(後続 phase): response["data"] から AlgoOrder 履歴 upsert
      response
    rescue StandardError => e
      log_reconcile_failure(:reconcile_orders_plan_history, e)
      nil
    end

    def reconcile_position_all(session)
      response = position_endpoint.position_all(margin_coin: session.margin_coin, symbol: session.symbol)
      # TODO(後続 phase): response["data"] から Exchange::PositionSnapshot upsert
      response
    rescue StandardError => e
      log_reconcile_failure(:reconcile_position_all, e)
      nil
    end

    # Phase 3.4-pre-4 追加: 直近 24h の約定履歴を取得(WS fill push 欠落分の補完).
    def reconcile_fill_history(session)
      end_time = (Time.current.to_f * 1000).to_i
      start_time = end_time - PLAN_HISTORY_LOOKBACK_MS

      response = account_endpoint.fill_history(
        symbol: session.symbol, start_time: start_time, end_time: end_time
      )
      # TODO(後続 phase): response["data"] から Exchange::Fill upsert + Trade 集計反映
      response
    rescue StandardError => e
      log_reconcile_failure(:reconcile_fill_history, e)
      nil
    end

    def log_reconcile_failure(label, error)
      logger.warn(
        "[ReconciliationCoordinator] #{label} failed: " \
        "#{error.class.name}: #{Domain::FailureReasonSanitizer.sanitize(error.message)}"
      )
    end
  end
end
