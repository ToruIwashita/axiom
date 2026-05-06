module Infrastructure
  # Bitget サーバ時刻と local 時刻の offset を保持し,WS heartbeat / order timestamp 等で
  # 利用可能な「同期済み now」を提供する(設計書 02_§4.2.7 / Phase 1.1 引き継ぎ #7)
  #
  # 定期同期は呼出側(LiveTradingWorker)の責務とし,本サービスは単一責務として
  # `sync!`(server_time 取得 + offset 更新)と `synced_now`(clock.call + offset)のみ提供。
  #
  # 防衛的設計:
  # - sync! 失敗時は offset を変更せず logger.error で記録のみ(従来の offset を維持)
  # - 初期 offset = 0 で synced_now == clock.call 相当
  class BitgetClockSync
    PATH_SERVER_TIME = "/api/v2/public/time".freeze

    private_constant :PATH_SERVER_TIME

    # @param rest_client [Infrastructure::BitgetRestClient]
    # @param clock [#call] local 時刻取得 Proc(default: Time.method(:current))
    # @param logger [Logger]
    def initialize(rest_client:, clock: Time.method(:current), logger: Rails.logger)
      @rest_client = rest_client
      @clock = clock
      @logger = logger
      @offset = 0.0
    end

    # @return [Float] サーバ - local 時刻のオフセット(秒)
    attr_reader :offset

    # 同期済 now を返す(local 時刻 + offset)
    #
    # @return [Time]
    def synced_now
      clock.call + offset
    end

    # サーバ時刻を取得して offset を更新する
    # 失敗時は offset 変更せず logger.error で記録(従来の offset を維持)
    #
    # @return [Float, nil] 更新後の offset(失敗時 nil)
    def sync!
      response = rest_client.request(
        :get, PATH_SERVER_TIME, auth: false, endpoint_key: :server_time
      )
      server_time_ms = response.fetch("data", {}).fetch("serverTime").to_i
      local_ms = (clock.call.to_f * 1000).to_i
      @offset = (server_time_ms - local_ms) / 1000.0
      logger.info("[BitgetClockSync] clock sync ok: offset=#{offset.round(3)}s")
      offset
    rescue StandardError => e
      logger.error("[BitgetClockSync] clock sync failed: #{e.class}: #{e.message}")
      nil
    end

    private

    attr_reader :rest_client, :clock, :logger
  end
end
