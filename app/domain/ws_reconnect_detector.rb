module Domain
  # Public / Private WS Client の reconnect_count 推移を監視し reconnection 検知を担う Domain サービス.
  #
  # Phase 3.4a Step 0b-3 で Worker 責務縮小のため抽出した.
  # 元: LiveTradingWorker @last_public_ws_reconnect_count / @last_private_ws_reconnect_count /
  #     @ws_reconnect_count_mutex + detect_ws_reconnect_and_reconcile + ws_reconnect_count helper.
  #
  # 責務:
  #   - 前回 snapshot 時の reconnect_count を thread-safe に保持(Mutex 保護)
  #   - 現在 count vs 保持 count の比較で「reconnect が発生したか」を判定
  #   - WS Client の `reconnect_count` メソッド未実装 / nil 入力に対する防御
  #
  # 利用パターン(Worker 側):
  #   detector.reset(public_ws: @public_ws, private_ws: @private_ws) # main loop 開始時
  #   loop do
  #     result = detector.snapshot(public_ws: @public_ws, private_ws: @private_ws)
  #     next unless result.any?
  #     # reconciliation 起動
  #     run_in_db_thread("...") do
  #       run_reconciliation_after_reconnect(...)
  #       detector.update_to(public_count: result.public_count, private_count: result.private_count)
  #     end
  #   end
  #
  # R-6 #10 反映: count update は reconciliation 完了後に行う(thread 例外時 carry 漏れ防止).
  class WsReconnectDetector
    # snapshot の戻り値: 検知結果 + 現在 count(後続 update_to に渡す用)+ source_event / target_ws.
    # Phase 4.0 #1 + 新-中-6 反映: WS Client の last_disconnect_reason を取り込み WsMetric.source_event に転記する.
    # 新々-中-3 反映: target_ws 判定ロジック(Public のみ → "public" / Private のみ → "private" / 両方 → "both").
    #
    # 【消費先の状態 / multi-agent review Agent 2 高-1 反映】
    # source_event / target_ws フィールドは Phase 4.2 で LiveTrading::WsMetric.create! の
    # 対応カラム(source_event / target_ws)に転記される計画(02_§3.7 設計書参照).
    # Phase 4.0 範囲では Result 拡張 + WS Client 経路の Detector 取り込みのみを先行追加し,
    # WsMetric 永続化経路への配線は Phase 4.2(SessionMonitorService + Worker 統合)で実装される.
    Result = Struct.new(:public_reconnected, :private_reconnected, :public_count, :private_count, :source_event, :target_ws, keyword_init: true) do
      def any?
        public_reconnected || private_reconnected
      end
    end

    def initialize
      @last_public_count = 0
      @last_private_count = 0
      @mutex = Mutex.new
    end

    # 現在の reconnect_count を初期値として記録する(main loop 開始時に 1 度呼ぶ).
    #
    # @param public_ws [#reconnect_count, nil]
    # @param private_ws [#reconnect_count, nil]
    # @return [void]
    def reset(public_ws:, private_ws:)
      @mutex.synchronize do
        @last_public_count = read_count(public_ws)
        @last_private_count = read_count(private_ws)
      end
      nil
    end

    # 現在の reconnect_count と保持 count を比較し reconnection 検知結果を返す.
    # 内部 count は更新しない(reconciliation 完了後に update_to で更新するパターンのため).
    #
    # @param public_ws [#reconnect_count, nil]
    # @param private_ws [#reconnect_count, nil]
    # @return [Result]
    def snapshot(public_ws:, private_ws:)
      public_count = read_count(public_ws)
      private_count = read_count(private_ws)
      last_public, last_private = @mutex.synchronize do
        [ @last_public_count, @last_private_count ]
      end

      public_reconnected = public_count > last_public
      private_reconnected = private_count > last_private

      # 新々-中-3 反映: target_ws を delta の発生側で決定. 両方 delta > 0 の場合は "both".
      target_ws = compute_target_ws(public_reconnected:, private_reconnected:)
      # 新-中-6 反映: source_event は対応 WS Client の last_disconnect_reason を読み取る.
      # 両方発生時(both)は Public 優先(Public/Private 同時切断時は通常 Public 側で先にイベント発火するため).
      source_event = compute_source_event(
        public_ws: public_ws,
        private_ws: private_ws,
        public_reconnected: public_reconnected,
        private_reconnected: private_reconnected
      )

      Result.new(
        public_reconnected: public_reconnected,
        private_reconnected: private_reconnected,
        public_count: public_count,
        private_count: private_count,
        source_event: source_event,
        target_ws: target_ws
      )
    end

    # reconnection 検知後の reconciliation 完了を受けて保持 count を更新する.
    # 通常は snapshot で得た public_count / private_count を渡す.
    #
    # 注意: snapshot 時点 count まで前進させるのみで,reconciliation 中に再 reconnect が
    # 起きて exchange 側 count がさらに進んでいた場合(例: snapshot=N+1 / reconciliation 中に
    # 再 reconnect で count=N+2),次回 main loop iteration の snapshot で `N+2 > N+1` のため
    # 再検知される(carry 漏れではなく一度の reconciliation で `N+2` まで吸収しない設計).
    # この再検知を意図する場合は `monotonic`(現値より小さい更新を無視)で安全に呼べる.
    #
    # @param public_count [Integer]
    # @param private_count [Integer]
    # @return [void]
    def update_to(public_count:, private_count:)
      @mutex.synchronize do
        # snapshot 時点 count より小さい値で上書きしない(monotonic 保証).
        @last_public_count = public_count if public_count > @last_public_count
        @last_private_count = private_count if private_count > @last_private_count
      end
      nil
    end

    private

    # WS Client から reconnect_count を安全に取得する(nil 防御 + respond_to? 防御).
    def read_count(ws)
      return 0 unless ws&.respond_to?(:reconnect_count)

      ws.reconnect_count.to_i
    end

    # 新々-中-3 反映: target_ws 決定ロジック.
    # @return [String, nil] "public" / "private" / "both" / 検知なし時 nil
    def compute_target_ws(public_reconnected:, private_reconnected:)
      return "both" if public_reconnected && private_reconnected
      return "public" if public_reconnected
      return "private" if private_reconnected

      nil
    end

    # 新-中-6 反映: source_event 決定ロジック. delta 発生側 WS Client の last_disconnect_reason を採用.
    # 両方発生(both)時は Public 優先(同時切断は通常 Public 側で先にイベント発火 / 詳細追跡は Phase 5b で
    # callback push 化により Public/Private 個別記録に再設計).
    # @return [Symbol, nil] :close / :error / :heartbeat_timeout / 検知なしや WS Client 未対応時 nil
    def compute_source_event(public_ws:, private_ws:, public_reconnected:, private_reconnected:)
      return read_disconnect_reason(public_ws) if public_reconnected
      return read_disconnect_reason(private_ws) if private_reconnected

      nil
    end

    # WS Client から last_disconnect_reason を安全に取得する(respond_to? 防御 / 既存 WS Client 互換).
    # peer AI レビュー 中-1 反映: WS Client 内部は Symbol(:close / :error / :heartbeat_timeout)で保持し,
    # Detector で String 化することで WsMetric DB カラム(varchar / SOURCE_EVENTS = %w[close error heartbeat_timeout])
    # との型一致 + inclusion validation との整合性を Detector 境界で確保する.
    def read_disconnect_reason(ws)
      return nil unless ws&.respond_to?(:last_disconnect_reason)

      ws.last_disconnect_reason&.to_s
    end
  end
end
