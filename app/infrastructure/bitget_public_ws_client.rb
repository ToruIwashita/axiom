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
    DEFAULT_WAIT_OPEN_TIMEOUT = 5.0
    DEFAULT_WAIT_OPEN_POLL_INTERVAL = 0.01

    class ConnectionError < StandardError; end

    # @param paptrading_enabled [Boolean] Demo環境(`wspap.bitget.com`)を使うか
    # @param url [String, nil] URL を明示指定する場合のオーバーライド(nil なら paptrading_enabled で自動選択)
    # @param ws_factory [#call] `->(url) { WebSocket::Client::Simple.connect(url) }` 相当の DI 用 Proc
    # @param decoder [#decode] 受信メッセージを Result に変換するデコーダ
    # @param clock [#call] 単調増加時刻を返すクロージャ(テスト用 DI)
    # @param logger [Logger] ログ出力先
    def initialize(
      paptrading_enabled: false,
      url: nil,
      ws_factory: default_ws_factory,
      decoder: Infrastructure::BitgetPublicWsMessageDecoder,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      logger: Rails.logger
    )
      @paptrading_enabled = paptrading_enabled
      @url_override = url
      @ws_factory = ws_factory
      @decoder = decoder
      @clock = clock
      @logger = logger
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
        establish_connection_internal
        subscriptions.keys.dup
      end
      wait_until_open
      send_subscribe(list_to_subscribe) unless list_to_subscribe.empty?
    end

    # WebSocket 接続を切断する。stop_requested フラグを立てて heartbeat スレッドを停止し,ws を close する。
    #
    # @param thread_join_timeout [Float] heartbeat スレッドの join タイムアウト(秒)
    # @return [void]
    def disconnect(thread_join_timeout: DEFAULT_THREAD_JOIN_TIMEOUT)
      thread_to_join, ws_to_close = mutex.synchronize do
        @stop_requested = true
        [ @heartbeat_thread, @ws ]
      end
      thread_to_join&.join(thread_join_timeout)
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

    private

    attr_reader :paptrading_enabled, :url_override, :ws_factory, :decoder, :clock, :logger,
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
      ws.on(:message) { |msg| handle_message(msg.data) }
      ws.on(:open)    { handle_open }
      ws.on(:close)   { handle_disconnection(:close) }
      ws.on(:error)   { |err| handle_disconnection(:error, err) }
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

    # ===== Step 5 以降で実装する機能のスタブ(Step 4 では空 list 受け付けのみ) =====

    def send_subscribe(_list)
      # Step 5 で本実装(JSON 整形 + ws.send)
    end

    # ===== Step 8 以降で実装される受信処理のスタブ(Step 4 段階では何もしない) =====

    def handle_message(_raw)
      # Step 6: pong 判定 / Step 8: dispatch を実装
    end

    def handle_disconnection(_reason, _error = nil)
      # Step 7 で実装(stop_requested 判定 + reconnect トリガー)
    end

    def default_ws_factory
      ->(url) { WebSocket::Client::Simple.connect(url) }
    end
  end
end
