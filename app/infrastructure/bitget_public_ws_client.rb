module Infrastructure
  # Bitget Public WebSocket への接続/購読/heartbeat/再接続/受信ディスパッチを担当するクライアント。
  #
  # スコープは Public チャネル(ticker / candle<interval> / books / books1 / books5 / books15)に限定。
  # Private チャネル(login + 認証必須)は Phase 3 で `BitgetPrivateWsClient` として別実装する。
  #
  # ## スレッド設計
  # - `connect` で受信スレッド(`websocket-client-simple` 内部) + heartbeat スレッド(本クラス内部)を起動
  # - 呼び出し側はノンブロッキングで戻り,`disconnect` で安全に停止
  #
  # ## Mutex 粒度ルール
  # - `subscriptions` Hash の全アクセスは mutex 内で行う
  # - mutex 内では I/O(`ws.send` 等)を呼ばず,送信対象 list を mutex 内で取得 → mutex 外で送信
  # - 状態変更(`@ws` / `@stop_requested` / `@subscriptions`)の書き込みは mutex 内
  class BitgetPublicWsClient
    DEFAULT_PRODUCTION_URL = "wss://ws.bitget.com/v2/ws/public".freeze
    DEFAULT_PAPTRADING_URL = "wss://wspap.bitget.com/v2/ws/public".freeze
    DEFAULT_THREAD_JOIN_TIMEOUT = 5.0
    DEFAULT_WAIT_OPEN_TIMEOUT = 10.0
    DEFAULT_WAIT_OPEN_POLL_INTERVAL = 0.01
    # Bitget WS 公式仕様(05_§3.5): 30 秒ごとに "ping",2 分未受信で切断。
    # ヘッダーマージンを取り 60 秒(= interval × 2)で pong タイムアウトと判定する。
    DEFAULT_HEARTBEAT_INTERVAL = 30.0
    DEFAULT_HEARTBEAT_TIMEOUT = 60.0
    # 再接続の指数バックオフ。Bitget のリリース時間帯切断 + 24 時間強制切断を前提に
    # 初期 1 秒で開始し,接続失敗が連続しても 30 秒上限で再試行を継続する。
    DEFAULT_RECONNECT_INITIAL_INTERVAL = 1.0
    DEFAULT_RECONNECT_MAX_INTERVAL = 30.0

    class ConnectionError < StandardError; end

    # @param paptrading_enabled [Boolean] Demo環境(`wspap.bitget.com`)を使うか
    # @param url [String, nil] URL を明示指定する場合のオーバーライド(nil なら paptrading_enabled で自動選択)
    # @param ws_factory [#call] `->(url) { WebSocket::Client::Simple.connect(url) }` 相当の DI 用 Proc
    # @param decoder [#decode] 受信メッセージを Result に変換するデコーダ
    # @param clock [#call] 単調増加時刻を返すクロージャ(テスト用 DI)
    # @param logger [Logger] ログ出力先
    # @param heartbeat_interval [Float] ping 送信間隔(秒)
    # @param heartbeat_timeout [Float] pong 未受信タイムアウト(秒)
    # @param reconnect_initial_interval [Float] 再接続の初期 sleep 秒数
    # @param reconnect_max_interval [Float] 再接続の最大 sleep 秒数(指数バックオフの上限)
    def initialize(
      paptrading_enabled: false,
      url: nil,
      ws_factory: default_ws_factory,
      decoder: Infrastructure::BitgetPublicWsMessageDecoder,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      logger: Rails.logger,
      heartbeat_interval: DEFAULT_HEARTBEAT_INTERVAL,
      heartbeat_timeout: DEFAULT_HEARTBEAT_TIMEOUT,
      reconnect_initial_interval: DEFAULT_RECONNECT_INITIAL_INTERVAL,
      reconnect_max_interval: DEFAULT_RECONNECT_MAX_INTERVAL
    )
      @paptrading_enabled = paptrading_enabled
      @url_override = url
      @ws_factory = ws_factory
      @decoder = decoder
      @clock = clock
      @logger = logger
      @heartbeat_interval = heartbeat_interval
      @heartbeat_timeout = heartbeat_timeout
      @reconnect_initial_interval = reconnect_initial_interval
      @reconnect_max_interval = reconnect_max_interval
      @subscriptions = {}
      @ws = nil
      @heartbeat_thread = nil
      @stop_requested = false
      @open_event_received = false
      @last_pong_at = nil
      @mutex = Mutex.new
    end

    # WebSocket 接続を確立する。
    #
    # mutex 内で `@ws` セット + callback 登録を行い,mutex 外で open 待ち + 既存購読の再送信を行う。
    #
    # @return [void]
    # @raise [ConnectionError] 既に接続中の場合,または open 待機タイムアウト
    def connect
      list_to_subscribe = mutex.synchronize do
        raise ConnectionError, "already connected" if connected_internal?

        @stop_requested = false
        @open_event_received = false
        @last_pong_at = clock.call
        establish_connection_internal
        subscriptions.keys.dup
      end

      # Phase 1.3 obs-6 反映: wait_until_open 例外時に @ws をクリーンアップしてから再 raise
      begin
        wait_until_open
      rescue ConnectionError
        cleanup_ws_after_open_failure
        raise
      end

      send_subscribe(list_to_subscribe) unless list_to_subscribe.empty?
      start_heartbeat_thread
    end

    # WebSocket 接続を切断する。stop_requested フラグを立てて heartbeat スレッドを停止し,ws を close する。
    # Phase 1.3 obs-7 反映: thread.join(timeout) 後も alive な場合は Thread#kill で最終救済する
    # (heartbeat sleep 中で stop_requested チェックが届かずゾンビ化するケースの safety net)
    #
    # @param thread_join_timeout [Float] heartbeat スレッドの join タイムアウト(秒)
    # @return [void]
    def disconnect(thread_join_timeout: DEFAULT_THREAD_JOIN_TIMEOUT)
      thread_to_join, ws_to_close = mutex.synchronize do
        @stop_requested = true
        [ @heartbeat_thread, @ws ]
      end
      thread_to_join&.join(thread_join_timeout)
      thread_to_join.kill if thread_to_join&.alive?
      ws_to_close&.close
      mutex.synchronize do
        @heartbeat_thread = nil
        @ws = nil
      end
    end

    # 接続中か判定する
    #
    # @return [Boolean]
    def connected?
      mutex.synchronize { connected_internal? }
    end

    # チャネルを購読する。
    # 接続中であれば即座に subscribe メッセージを送信し,切断中であれば内部購読リストにのみ登録される
    # (次回 `connect` 時にまとめて再送信される)。
    #
    # @param subscription [Infrastructure::BitgetPublicWsSubscription]
    # @yield [data, result] 該当チャネルの push データと Result(任意,Step 8 で dispatch から呼び出される)
    # @return [void]
    def subscribe(subscription, &callback)
      send_target = mutex.synchronize do
        subscriptions[subscription] = callback
        connected_internal? ? [ subscription ] : nil
      end
      send_subscribe(send_target) if send_target
    end

    # チャネル購読を解除する。
    # 接続中であれば即座に unsubscribe メッセージを送信し,内部購読リストからも削除する。
    # 未登録の subscription を渡された場合は例外なく完了する(ws.send も呼ばない)。
    #
    # @param subscription [Infrastructure::BitgetPublicWsSubscription]
    # @return [void]
    def unsubscribe(subscription)
      send_target = mutex.synchronize do
        next nil unless subscriptions.key?(subscription)

        subscriptions.delete(subscription)
        connected_internal? ? [ subscription ] : nil
      end
      send_unsubscribe(send_target) if send_target
    end

    private

    attr_reader :paptrading_enabled, :url_override, :ws_factory, :decoder, :clock, :logger,
                :heartbeat_interval, :heartbeat_timeout,
                :reconnect_initial_interval, :reconnect_max_interval,
                :subscriptions, :mutex
    attr_accessor :ws, :heartbeat_thread, :stop_requested, :open_event_received, :last_pong_at

    # mutex 内で呼ばれる前提の接続状態判定(再帰ロック回避)
    def connected_internal?
      !ws.nil? && !stop_requested
    end

    def url
      url_override || (paptrading_enabled ? DEFAULT_PAPTRADING_URL : DEFAULT_PRODUCTION_URL)
    end

    # WebSocket 接続を確立し callback を登録する(mutex 内で呼ばれる前提,I/O は呼ばない)
    def establish_connection_internal
      @ws = ws_factory.call(url)
      attach_callbacks(@ws)
    end

    def attach_callbacks(ws)
      # event_emitter gem は instance_exec で callback を呼ぶため,ブロック内の `self` は
      # WebSocket::Client::Simple::Client に変わる。外側 self を `this` として捕捉して呼び出す。
      this = self
      ws.on(:message) { |msg| this.send(:handle_message, msg.data) }
      ws.on(:open)    { this.send(:handle_open) }
      ws.on(:close)   { this.send(:handle_disconnection, :close) }
      ws.on(:error)   { |err| this.send(:handle_disconnection, :error, err) }
    end

    def handle_open
      @open_event_received = true
      @last_pong_at = clock.call
    end

    # WebSocket open イベントを待機する。
    # spec ではスタブ化されるため実装は最小限(open フラグ + sleep ループ + timeout)。
    def wait_until_open(timeout: DEFAULT_WAIT_OPEN_TIMEOUT, poll_interval: DEFAULT_WAIT_OPEN_POLL_INTERVAL)
      deadline = clock.call + timeout
      loop do
        return if open_event_received
        raise ConnectionError, "WebSocket open timeout (#{timeout}s)" if clock.call > deadline

        sleep(poll_interval)
      end
    end

    # ===== I/O 実行: mutex 外で呼ばれる前提(ws.send 内部の mutex とのロック順序逆転を防ぐ) =====

    def send_subscribe(list)
      send_op_message(op: "subscribe", list: list)
    end

    def send_unsubscribe(list)
      send_op_message(op: "unsubscribe", list: list)
    end

    def send_op_message(op:, list:)
      payload = { op: op, args: list.map(&:to_args_hash) }
      ws.send(payload.to_json)
    end

    # ===== Heartbeat 関連(設計書 §3.5: 30 秒 ping / 2 分未受信切断) =====

    def start_heartbeat_thread
      @heartbeat_thread = Thread.new { heartbeat_loop }
    end

    def heartbeat_loop
      loop do
        break if stop_requested

        sleep(heartbeat_interval)
        break if stop_requested

        safe_heartbeat_tick
      end
    end

    # heartbeat_tick の例外を握りつぶしてログ出力するラッパー(完了レビュー観察1 対応)。
    # heartbeat スレッドが silent 死亡すると ping/pong 監視 + 再接続トリガーが停止するため,
    # 例外を捕捉してループは継続させる(次の sleep サイクルで再試行)。
    def safe_heartbeat_tick
      heartbeat_tick
    rescue StandardError => e
      logger.error("[BitgetPublicWsClient] heartbeat error: #{e.class}: #{e.message}")
    end

    def heartbeat_tick
      send_ping
      check_pong_timeout
    end

    def send_ping
      ws&.send("ping")
    end

    def check_pong_timeout
      return if last_pong_at.nil?

      elapsed = clock.call - last_pong_at
      trigger_reconnect(:heartbeat_timeout) if elapsed > heartbeat_timeout
    end

    # ===== 受信メッセージ処理(Step 6: pong / Step 8: dispatch) =====

    def handle_message(raw)
      if raw == "pong"
        @last_pong_at = clock.call
      else
        dispatch(decoder.decode(raw))
      end
    end

    # Decoder の Result 型を述語メソッドで分岐(設計時レビュー重要3 対応:
    # private_constant の Decoder::Result::* を case/when で参照しない)
    def dispatch(result)
      if result.push?
        callback = lookup_callback(result.arg)
        callback&.call(result.data, result)
      elsif result.event?
        logger.warn("[BitgetPublicWsClient] event error: #{result.message}") if result.error?
      elsif result.parse_error?
        logger.warn("[BitgetPublicWsClient] parse error: #{result.error.message}")
      end
    end

    # arg Hash から購読対象を構築し対応する callback を返す。
    # 完了レビュー観察2 対応: Bitget が予期しない arg(必須キー欠落 / nil 等)を返した場合の
    # ArgumentError を捕捉する。受信スレッドが死亡すると close/error callback も発火せず
    # 再接続不能になる致命的問題を防ぐ。
    def lookup_callback(arg)
      subscription = Infrastructure::BitgetPublicWsSubscription.new(
        channel: arg["channel"],
        inst_type: arg["instType"],
        inst_id: arg["instId"]
      )
      mutex.synchronize { subscriptions[subscription] }
    rescue ArgumentError => e
      logger.warn("[BitgetPublicWsClient] invalid push arg: #{arg.inspect} (#{e.message})")
      nil
    end

    # ws.on(:close) / ws.on(:error) callback または heartbeat タイムアウトから呼ばれる切断検知ハンドラ。
    # disconnect 中(stop_requested=true)は再接続しない。
    def handle_disconnection(reason, error = nil)
      return if stop_requested

      trigger_reconnect(reason, error)
    end

    def trigger_reconnect(reason, error = nil)
      message = "[BitgetPublicWsClient] reconnect triggered: #{reason}"
      message += " (#{error.message})" if error
      logger.warn(message)
      reconnect_with_backoff
    end

    # 指数バックオフで再接続を試行する。
    # - sleep の前後で stop_requested をチェックし,disconnect 中の establish_connection を防ぐ(設計時レビュー重要2)
    # - 接続成功時は既存購読を resubscribe してから return
    # - 接続失敗時は interval を 2 倍にしてリトライ(reconnect_max_interval で頭打ち)
    def reconnect_with_backoff
      interval = reconnect_initial_interval
      loop do
        break if stop_requested

        sleep(interval)
        break if stop_requested

        begin
          list_to_resubscribe = mutex.synchronize do
            next nil if stop_requested

            establish_connection_internal
            subscriptions.keys.dup
          end
          next if list_to_resubscribe.nil?

          wait_until_open
          send_subscribe(list_to_resubscribe) unless list_to_resubscribe.empty?
          return
        rescue StandardError => e
          # Phase 1.3 obs-6 反映: wait_until_open 失敗等で @ws を取り残さない
          cleanup_ws_after_open_failure
          logger.warn("[BitgetPublicWsClient] reconnect failed: #{e.message}")
          interval = [ interval * 2, reconnect_max_interval ].min
        end
      end
    end

    # Phase 1.3 obs-6 反映: open 失敗時に @ws を close + nil クリアし,後続の establish/connected? が
    # 整合するようにする(未クリーンアップだと「ws.nil? は false だが open 未完了」の中途半端状態が残る)
    def cleanup_ws_after_open_failure
      ws_to_close = mutex.synchronize do
        closed = @ws
        @ws = nil
        closed
      end
      ws_to_close&.close
    end

    def default_ws_factory
      ->(url) { WebSocket::Client::Simple.connect(url) }
    end
  end
end
