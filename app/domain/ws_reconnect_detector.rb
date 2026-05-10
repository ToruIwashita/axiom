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
    # snapshot の戻り値: 検知結果 + 現在 count(後続 update_to に渡す用).
    Result = Struct.new(:public_reconnected, :private_reconnected, :public_count, :private_count, keyword_init: true) do
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

      Result.new(
        public_reconnected: public_count > last_public,
        private_reconnected: private_count > last_private,
        public_count: public_count,
        private_count: private_count
      )
    end

    # reconnection 検知後の reconciliation 完了を受けて保持 count を更新する.
    # 通常は snapshot で得た public_count / private_count を渡す.
    #
    # @param public_count [Integer]
    # @param private_count [Integer]
    # @return [void]
    def update_to(public_count:, private_count:)
      @mutex.synchronize do
        @last_public_count = public_count
        @last_private_count = private_count
      end
      nil
    end

    private

    # WS Client から reconnect_count を安全に取得する(nil 防御 + respond_to? 防御).
    def read_count(ws)
      return 0 unless ws&.respond_to?(:reconnect_count)

      ws.reconnect_count.to_i
    end
  end
end
