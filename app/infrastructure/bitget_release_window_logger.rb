module Infrastructure
  # Bitget の主要リリース時間帯(UTC+8 の火/水/木 14-17 時 = UTC 06-09 時)を判定し,
  # ログメッセージにタグを付与するヘルパー(設計書 02_§4.2.9 / Phase 1.3 引き継ぎ #10)
  #
  # この時間帯は Bitget 側のメンテナンス / リリース起因の API 不安定が発生する
  # 可能性があるため,ログに `[bitget_release_window]` タグを付与し後段の運用調査を
  # 容易にする。
  #
  # 本クラスは純粋関数のみ(stateless)。BitgetRestClient のミドルウェア組込みは
  # 呼出側責務(Phase 3.3 の LiveTradingWorker / API ラッパーで適用判断)。
  class BitgetReleaseWindowLogger
    RELEASE_WINDOW_DAYS = %i[tuesday wednesday thursday].freeze
    RELEASE_WINDOW_START_HOUR_UTC = 6
    RELEASE_WINDOW_END_HOUR_UTC = 9
    TAG = "[bitget_release_window]".freeze

    private_constant :RELEASE_WINDOW_DAYS,
                     :RELEASE_WINDOW_START_HOUR_UTC,
                     :RELEASE_WINDOW_END_HOUR_UTC,
                     :TAG

    # 指定時刻が Bitget リリース時間帯か判定する
    # UTC+8 の火/水/木 14:00-17:00 を UTC で 06:00-09:00 として判定
    #
    # @param time [Time] 判定対象時刻(UTC 推奨)
    # @return [Boolean]
    def self.release_window?(time)
      utc = time.utc
      RELEASE_WINDOW_DAYS.include?(utc.strftime("%A").downcase.to_sym) &&
        utc.hour >= RELEASE_WINDOW_START_HOUR_UTC &&
        utc.hour < RELEASE_WINDOW_END_HOUR_UTC
    end

    # リリース時間帯であればメッセージにタグを付加して返す
    #
    # @param message [String]
    # @param time [Time] 判定対象時刻
    # @return [String] タグ付きまたは元のまま
    def self.tag_if_release_window(message:, time:)
      return message unless release_window?(time)

      "#{TAG} #{message}"
    end
  end
end
