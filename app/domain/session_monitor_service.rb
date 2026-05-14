module Domain
  # LiveTrading::Session の監視 Domain サービス(Phase 4.2).
  #
  # 設計書 02_§3.5 / 03_§3.3.
  #
  # ## 提供機能
  # - heartbeat 経過秒数 / lease 残り秒数 / WS reconnect 状況の取得
  # - 死活 alert 判定(heartbeat_timeout / lease_expired / ws_consecutive_reconnect)
  # - クラスメソッド `.bulk_monitor(sessions:)` で N+1 回避(高-3 反映)
  # - インスタンスメソッド `#recent_heartbeats` / `#lease_events` / `#recent_ws_metrics_grouped_by_worker`
  #   で show 画面 partial 用データ提供 + memoize(新-中-5 反映)
  class SessionMonitorService
    HEARTBEAT_TIMEOUT_SECONDS = 65    # 60 + α
    LEASE_WARN_THRESHOLD_SECONDS = 60
    WS_CONSECUTIVE_THRESHOLD = 5
    WS_CONSECUTIVE_WINDOW_SECONDS = 300

    private_constant :HEARTBEAT_TIMEOUT_SECONDS,
                     :LEASE_WARN_THRESHOLD_SECONDS,
                     :WS_CONSECUTIVE_THRESHOLD,
                     :WS_CONSECUTIVE_WINDOW_SECONDS

    # 一覧画面用: 複数 session を一括 monitor(高-3 反映 / N+1 回避).
    #
    # 4 SQL で N session 一括取得:
    # 1. 最新 heartbeat(session_id, MAX(pulsed_at) サブクエリ)
    # 2. SessionLease(has_one)
    # 3. 最新 WsMetric(session_id, MAX(detected_at) サブクエリ)
    # 4. WS reconnect window 内 delta sum(group by session_id)
    #
    # @param sessions [Enumerable<LiveTrading::Session>] eager load 済を期待
    # @param clock [#call] テスト用 DI
    # @return [Hash{Integer => Hash}] session.id をキーとする monitor Hash
    def self.bulk_monitor(sessions:, clock: Time.method(:current))
      session_ids = sessions.map(&:id)
      now = clock.call

      latest_heartbeats = LiveTrading::SessionHeartbeat
        .where(live_trading_session_id: session_ids)
        .where(
          "(live_trading_session_id, pulsed_at) IN (SELECT live_trading_session_id, MAX(pulsed_at) " \
          "FROM live_trading_session_heartbeats WHERE live_trading_session_id IN (?) GROUP BY live_trading_session_id)",
          session_ids
        )
        .index_by(&:live_trading_session_id)

      leases = LiveTrading::SessionLease
        .where(live_trading_session_id: session_ids)
        .index_by(&:live_trading_session_id)

      latest_ws_metrics = LiveTrading::WsMetric
        .where(live_trading_session_id: session_ids)
        .where(
          "(live_trading_session_id, detected_at) IN (SELECT live_trading_session_id, MAX(detected_at) " \
          "FROM live_trading_ws_metrics WHERE live_trading_session_id IN (?) GROUP BY live_trading_session_id)",
          session_ids
        )
        .index_by(&:live_trading_session_id)

      consecutive_sums = LiveTrading::WsMetric
        .where(live_trading_session_id: session_ids)
        .where(detected_at: (now - WS_CONSECUTIVE_WINDOW_SECONDS)..)
        .group(:live_trading_session_id)
        .sum(Arel.sql("delta_public + delta_private"))

      sessions.each_with_object({}) do |session, acc|
        acc[session.id] = compute_monitor_hash(
          session, now,
          latest_heartbeats[session.id],
          leases[session.id],
          latest_ws_metrics[session.id],
          consecutive_sums[session.id] || 0
        )
      end
    end

    # 詳細画面用: 単一 session 用(従来 API).
    #
    # @param session [LiveTrading::Session]
    # @param clock [#call]
    # @param logger [Logger]
    def initialize(session:, clock: Time.method(:current), logger: Rails.logger)
      @session = session
      @clock = clock
      @logger = logger
    end

    def heartbeat_elapsed_seconds
      last = session.session_heartbeats.recent(1).first
      return nil unless last

      (clock.call - last.pulsed_at).to_i
    end

    def lease_remaining_seconds
      lease = session.session_lease
      return nil unless lease&.state_active?

      (lease.expires_at - clock.call).to_i
    end

    def ws_reconnect_status
      metric = session.ws_metrics.recent(1).first
      return nil unless metric

      {
        public_count_since_start: metric.public_count_since_start,
        private_count_since_start: metric.private_count_since_start,
        last_detected_at: metric.detected_at,
        source_event: metric.source_event,
        target_ws: metric.target_ws
      }
    end

    def alerts
      arr = []
      arr << :heartbeat_timeout if heartbeat_timeout?
      arr << :lease_expired if lease_expired?
      arr << :ws_consecutive_reconnect if ws_consecutive_reconnect?
      arr
    end

    # 新-中-5 反映: show partial 用 / memoize でクエリ重複排除
    def recent_heartbeats(limit)
      @recent_heartbeats ||= {}
      @recent_heartbeats[limit] ||= session.session_heartbeats.recent(limit).to_a
    end

    def lease_events
      @lease_events ||= [ session.session_lease ].compact
    end

    # 新-中-4 反映: WsMetric を worker_instance_id 別にグループ化
    def recent_ws_metrics_grouped_by_worker(limit)
      @recent_ws_metrics_grouped ||= {}
      @recent_ws_metrics_grouped[limit] ||= session.ws_metrics
                                                     .order(detected_at: :desc)
                                                     .limit(limit * 5)
                                                     .group_by(&:worker_instance_id)
                                                     .transform_values { |arr| arr.first(limit) }
    end

    private

    attr_reader :session, :clock, :logger

    def heartbeat_timeout?
      elapsed = heartbeat_elapsed_seconds
      !elapsed.nil? && elapsed > HEARTBEAT_TIMEOUT_SECONDS
    end

    def lease_expired?
      lease = session.session_lease
      return false unless lease&.state_active?

      lease.expires_at < clock.call
    end

    # 中-6 反映: window 内 delta_public + delta_private の sum で判定
    def ws_consecutive_reconnect?
      window_start = clock.call - WS_CONSECUTIVE_WINDOW_SECONDS
      sum = session.ws_metrics.where(detected_at: window_start..)
                                .sum(Arel.sql("delta_public + delta_private"))
      sum >= WS_CONSECUTIVE_THRESHOLD
    end

    def self.compute_monitor_hash(session, now, heartbeat, lease, ws_metric, consecutive_sum)
      elapsed = heartbeat ? (now - heartbeat.pulsed_at).to_i : nil
      lease_remaining = (lease&.state_active?) ? (lease.expires_at - now).to_i : nil
      alerts = []
      alerts << :heartbeat_timeout if elapsed && elapsed > HEARTBEAT_TIMEOUT_SECONDS
      alerts << :lease_expired if lease&.state_active? && lease.expires_at < now
      alerts << :ws_consecutive_reconnect if consecutive_sum >= WS_CONSECUTIVE_THRESHOLD

      {
        heartbeat_elapsed_seconds: elapsed,
        last_heartbeat_at: heartbeat&.pulsed_at,
        lease_remaining_seconds: lease_remaining,
        lease_status: lease&.status,
        lease_expires_at: lease&.expires_at,
        ws_status: ws_metric ? {
          public_count_since_start: ws_metric.public_count_since_start,
          private_count_since_start: ws_metric.private_count_since_start,
          last_detected_at: ws_metric.detected_at,
          source_event: ws_metric.source_event,
          target_ws: ws_metric.target_ws
        } : nil,
        alerts: alerts
      }
    end
    private_class_method :compute_monitor_hash
  end
end
