module Infrastructure
  # Bitget Private WebSocket への接続/login 認証/購読/heartbeat/再接続/受信ディスパッチ。
  # 設計書 05_§3.4 / §3.5 / §3.6 / 02_§4.2.1 反映。
  #
  # Public 版(BitgetPublicWsClient)と構造を踏襲しつつ以下が異なる:
  # - URL: `wss://[ws/wspap].bitget.com/v2/ws/private`
  # - 接続成功後 op:login + HMAC-SHA256 署名で認証 → 成功後に subscribe
  # - login 失敗時 LoginFailedError raise(LiveTradingWorker bootstrap step 10 で rescue)
  # - subscribe 6 チャネル(orders / orders-algo / fill / positions / positions-history / account)
  # - reconnect 後も自動 login + 既存購読 resubscribe
  class BitgetPrivateWsClient
    DEFAULT_PRODUCTION_URL = "wss://ws.bitget.com/v2/ws/private".freeze
    DEFAULT_PAPTRADING_URL = "wss://wspap.bitget.com/v2/ws/private".freeze
    DEFAULT_THREAD_JOIN_TIMEOUT = 5.0
    DEFAULT_WAIT_OPEN_TIMEOUT = 10.0
    DEFAULT_WAIT_OPEN_POLL_INTERVAL = 0.01
    DEFAULT_LOGIN_TIMEOUT = 10.0
    DEFAULT_HEARTBEAT_INTERVAL = 30.0
    DEFAULT_HEARTBEAT_TIMEOUT = 60.0
    DEFAULT_RECONNECT_INITIAL_INTERVAL = 1.0
    DEFAULT_RECONNECT_MAX_INTERVAL = 30.0
    LOGIN_VERIFY_PATH = "/user/verify".freeze

    private_constant :LOGIN_VERIFY_PATH

    class ConnectionError < StandardError; end
    class LoginFailedError < StandardError; end
    class SubscribeFailedError < StandardError; end

    # @param api_key [String] Bitget API key
    # @param passphrase [String] Bitget API passphrase
    # @param signer [Infrastructure::BitgetSigner] login 署名生成用
    # @param paptrading_enabled [Boolean] Demo環境(`wspap.bitget.com`)を使うか
    # @param url [String, nil] URL を明示指定する場合のオーバーライド
    # @param ws_factory [#call] DI 用 ws 生成 Proc
    # @param decoder [#decode] 受信メッセージを Result に変換するデコーダ
    # @param clock [#call] 単調増加時刻を返すクロージャ(テスト用 DI)
    # @param logger [Logger] ログ出力先
    # @param heartbeat_interval [Float] ping 送信間隔(秒)
    # @param heartbeat_timeout [Float] pong 未受信タイムアウト(秒)
    # @param reconnect_initial_interval [Float] 再接続の初期 sleep 秒数
    # @param reconnect_max_interval [Float] 再接続の最大 sleep 秒数
    # @param login_timeout [Float] login レスポンス待機タイムアウト
    # @param background_thread_registry [Domain::BackgroundThreadRegistry, nil]
    #   Phase 4.0 #1 反映: reconnect_with_backoff を別スレッドに逃がすための registry(sub-commit 1.2 で必須化予定)
    # @param clock_sync [Infrastructure::BitgetClockSync, nil]
    #   Phase 4.0 #2 反映: WS login signing 時の wallclock 直接使用回避(sub-commit 2.2 で `send_login` から参照)
    def initialize(
      api_key:,
      passphrase:,
      signer:,
      paptrading_enabled: false,
      url: nil,
      ws_factory: default_ws_factory,
      decoder: Infrastructure::BitgetPrivateWsMessageDecoder,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      logger: Rails.logger,
      heartbeat_interval: DEFAULT_HEARTBEAT_INTERVAL,
      heartbeat_timeout: DEFAULT_HEARTBEAT_TIMEOUT,
      reconnect_initial_interval: DEFAULT_RECONNECT_INITIAL_INTERVAL,
      reconnect_max_interval: DEFAULT_RECONNECT_MAX_INTERVAL,
      login_timeout: DEFAULT_LOGIN_TIMEOUT,
      background_thread_registry: nil,
      clock_sync: nil
    )
      @api_key = api_key
      @passphrase = passphrase
      @signer = signer
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
      @login_timeout = login_timeout
      @background_thread_registry = background_thread_registry
      @clock_sync = clock_sync
      @subscriptions = {}
      @ws = nil
      @heartbeat_thread = nil
      @stop_requested = false
      @open_event_received = false
      @login_completed = false
      @login_error = nil
      @last_pong_at = nil
      @reconnect_count = 0
      # Phase 4.0 #1 + 新-中-6 反映: 直近 disconnect 理由を保持(WsReconnectDetector が WsMetric.source_event に転記)
      @last_disconnect_reason = nil
      @mutex = Mutex.new
    end

    # 自動再接続の累計回数(LiveTradingWorker が 24h 切断後 reconciliation 再実行検知に利用 / 設計書 02_§5.2.6 + Phase 1.3 引き継ぎ #13).
    # `reconnect_with_backoff` が再接続成功するたびに increment される.
    # multiple-agent review R-2 #4 反映: increment / read を mutex で保護し non-atomic race を防ぐ.
    # @return [Integer]
    def reconnect_count
      mutex.synchronize { @reconnect_count }
    end

    # Phase 4.0 #1 + 新-中-6 反映: 直近の disconnect 理由を返す(mutex 同期 / WsReconnectDetector が読む).
    # @return [Symbol, nil] :close / :error / :heartbeat_timeout / 初期は nil
    def last_disconnect_reason
      mutex.synchronize { @last_disconnect_reason }
    end

    # WebSocket 接続を確立し,login + 既存購読の resubscribe を行う。
    #
    # @raise [ConnectionError] 既に接続中の場合,または open 待機タイムアウト
    # @raise [LoginFailedError] login 失敗 / login タイムアウト
    def connect
      list_to_subscribe = mutex.synchronize do
        raise ConnectionError, "already connected" if connected_internal?

        @stop_requested = false
        @open_event_received = false
        @login_completed = false
        @login_error = nil
        @last_pong_at = clock.call
        establish_connection_internal
        subscriptions.keys.dup
      end

      begin
        wait_until_open
        send_login
        wait_until_login
      rescue ConnectionError, LoginFailedError
        cleanup_ws_after_open_failure
        raise
      end

      send_subscribe(list_to_subscribe) unless list_to_subscribe.empty?
      start_heartbeat_thread
    end

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

    def connected?
      mutex.synchronize { connected_internal? }
    end

    def subscribe(subscription, &callback)
      send_target = mutex.synchronize do
        subscriptions[subscription] = callback
        connected_internal? ? [ subscription ] : nil
      end
      send_subscribe(send_target) if send_target
    end

    def unsubscribe(subscription)
      send_target = mutex.synchronize do
        next nil unless subscriptions.key?(subscription)

        subscriptions.delete(subscription)
        connected_internal? ? [ subscription ] : nil
      end
      send_unsubscribe(send_target) if send_target
    end

    private

    attr_reader :api_key, :passphrase, :signer,
                :paptrading_enabled, :url_override, :ws_factory, :decoder, :clock, :logger,
                :heartbeat_interval, :heartbeat_timeout,
                :reconnect_initial_interval, :reconnect_max_interval, :login_timeout,
                :background_thread_registry, :clock_sync,
                :subscriptions, :mutex
    attr_accessor :ws, :heartbeat_thread, :stop_requested, :open_event_received,
                  :login_completed, :login_error, :last_pong_at

    def connected_internal?
      !ws.nil? && !stop_requested
    end

    def url
      url_override || (paptrading_enabled ? DEFAULT_PAPTRADING_URL : DEFAULT_PRODUCTION_URL)
    end

    def establish_connection_internal
      @ws = ws_factory.call(url)
      attach_callbacks(@ws)
    end

    def attach_callbacks(ws)
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

    def wait_until_open(timeout: DEFAULT_WAIT_OPEN_TIMEOUT, poll_interval: DEFAULT_WAIT_OPEN_POLL_INTERVAL)
      deadline = clock.call + timeout
      loop do
        return if open_event_received
        raise ConnectionError, "WebSocket open timeout (#{timeout}s)" if clock.call > deadline

        sleep(poll_interval)
      end
    end

    # login メッセージ送信(設計書 05_§3.4 / Bitget V2 WS Private API 仕様)
    # preHash: timestamp(秒) + "GET" + "/user/verify"
    def send_login
      timestamp = Time.now.to_i
      sign = signer.sign(
        timestamp: timestamp,
        method: "GET",
        request_path: LOGIN_VERIFY_PATH
      )
      payload = {
        op: "login",
        args: [ {
          apiKey: api_key,
          passphrase: passphrase,
          timestamp: timestamp.to_s,
          sign: sign
        } ]
      }
      ws.send(payload.to_json)
    end

    # login レスポンス待機(handle_message で @login_completed / @login_error が更新される)
    # timeout=0 でも即時 raise させるため deadline 判定は `>=` を採用(Public 版 wait_until_open との差異)
    def wait_until_login(timeout: login_timeout, poll_interval: DEFAULT_WAIT_OPEN_POLL_INTERVAL)
      deadline = clock.call + timeout
      loop do
        raise LoginFailedError, login_error if login_error
        return if login_completed
        raise LoginFailedError, "login timeout (#{timeout}s)" if clock.call >= deadline

        sleep(poll_interval)
      end
    end

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

    def safe_heartbeat_tick
      heartbeat_tick
    rescue StandardError => e
      logger.error("[BitgetPrivateWsClient] heartbeat error: #{e.class}: #{e.message}")
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

    def handle_message(raw)
      if raw == "pong"
        @last_pong_at = clock.call
        return
      end

      result = decoder.decode(raw)

      # login レスポンスは subscribe より先に処理する必要があるため特別扱い
      if result.event? && result.event_name == "login"
        if result.login_success?
          @login_completed = true
        else
          # multi-agent review R-4 #10 反映: login error message に Bitget API key 等が
          # 将来含まれる可能性があるため, 永続化経路(LoginFailedError → DB failure_reason)に
          # 流す文字列は code のみに限定し, raw message は logger.warn のみに記録する.
          @login_error = "code=#{result.code}"
          logger.warn(
            "[BitgetPrivateWsClient] login error detail (not persisted): " \
            "code=#{result.code} msg=#{result.message}"
          )
        end
        return
      end

      dispatch(result)
    end

    def dispatch(result)
      if result.push?
        callback = lookup_callback(result.arg)
        callback&.call(result.data, result)
      elsif result.event?
        logger.warn("[BitgetPrivateWsClient] event error: #{result.message}") if result.error?
      elsif result.parse_error?
        logger.warn("[BitgetPrivateWsClient] parse error: #{result.error.message}")
      elsif result.unknown?
        logger.debug("[BitgetPrivateWsClient] unknown frame: #{result.inspect}")
      end
    end

    def lookup_callback(arg)
      # Bitget V2: account channel push は instId ではなく coin を含む.
      subscription =
        if arg.key?("coin")
          Infrastructure::BitgetPrivateWsSubscription.new(
            channel: arg["channel"],
            inst_type: arg["instType"],
            coin: arg["coin"]
          )
        else
          Infrastructure::BitgetPrivateWsSubscription.new(
            channel: arg["channel"],
            inst_type: arg["instType"],
            inst_id: arg["instId"]
          )
        end
      mutex.synchronize { subscriptions[subscription] }
    rescue ArgumentError => e
      logger.warn("[BitgetPrivateWsClient] invalid push arg: #{arg.inspect} (#{e.message})")
      nil
    end

    # ws.on(:close) / ws.on(:error) callback または heartbeat タイムアウトから呼ばれる切断検知ハンドラ。
    # Phase 4.0 #1 + 新-中-6 反映: @last_disconnect_reason に reason を記録(WsReconnectDetector が WsMetric.source_event に転記).
    def handle_disconnection(reason, error = nil)
      return if stop_requested

      mutex.synchronize { @last_disconnect_reason = reason }
      trigger_reconnect(reason, error)
    end

    # Phase 4.0 #1 sub-commit 1.2 反映: callback スレッドブロック解消のため
    # background_thread_registry が DI されている場合は `reconnect_with_backoff` を別スレッドで起動.
    # nil の場合は既存挙動(同期呼び出し)を維持 / LiveTradingWorker から DI 接続される sub-commit 2.3 で
    # 全経路 spawn 経由化される.
    def trigger_reconnect(reason, error = nil)
      message = "[BitgetPrivateWsClient] reconnect triggered: #{reason}"
      message += " (#{error.message})" if error
      logger.warn(message)

      if background_thread_registry
        background_thread_registry.spawn("bitget_private_ws_reconnect") do
          reconnect_with_backoff
        end
      else
        reconnect_with_backoff
      end
    end

    # 指数バックオフで再接続 + 自動 login + 既存購読 resubscribe.
    # Phase 4.0 #1 sub-commit 1.3 反映: ループ冒頭で旧 ws を mutex 内で取り外し → close 完了待機.
    # これにより旧 ws と新 ws の race(callback 重複登録 / push 受信ハンドラ重複)を解消する.
    def reconnect_with_backoff
      interval = reconnect_initial_interval
      loop do
        break if stop_requested

        # 旧 ws を mutex 内で取り外して close 完了待機(race 解消 / sub-commit 1.3 反映)
        # peer AI 新-中-2 反映: close 自体の例外を吸収して spawn thread の死亡を防ぐ
        old_ws = mutex.synchronize do
          ws_to_abandon = @ws
          @ws = nil
          ws_to_abandon
        end
        begin
          old_ws&.close
        rescue StandardError => e
          logger.warn("[BitgetPrivateWsClient] old ws close failed: #{e.message}")
        end

        sleep(interval)
        break if stop_requested

        begin
          list_to_resubscribe = mutex.synchronize do
            next nil if stop_requested

            @open_event_received = false
            @login_completed = false
            @login_error = nil
            establish_connection_internal
            subscriptions.keys.dup
          end
          next if list_to_resubscribe.nil?

          wait_until_open
          send_login
          wait_until_login
          send_subscribe(list_to_resubscribe) unless list_to_resubscribe.empty?
          mutex.synchronize { @reconnect_count += 1 }
          return
        rescue StandardError => e
          cleanup_ws_after_open_failure
          logger.warn("[BitgetPrivateWsClient] reconnect failed: #{e.message}")
          interval = [ interval * 2, reconnect_max_interval ].min
        end
      end
    end

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
