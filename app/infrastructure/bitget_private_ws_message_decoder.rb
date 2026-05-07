module Infrastructure
  # Bitget Private WebSocket から受信した生 JSON 文字列を解析し,
  # `Result::Event` / `Result::Push` / `Result::Unknown` / `Result::ParseError` のいずれかに分類する。
  #
  # Public 版(BitgetPublicWsMessageDecoder)と同等の階層構造を持ちつつ,
  # Private 固有のチャネル述語(orders? / orders_algo? / fill? / positions? /
  # positions_history? / account?)と orders-algo の状態別述語(algo_create? /
  # algo_triggered? / algo_cancelled? / algo_anomaly?)を Result::Push に追加する。
  #
  # 呼び出し側は Result の述語メソッドで型分岐する(設計時レビュー重要 3 対応:
  # private_constant の Result::* を case/when で参照しない方針を踏襲)。
  class BitgetPrivateWsMessageDecoder
    PRIVATE_CHANNELS = %w[orders orders-algo fill positions positions-history account].freeze
    private_constant :PRIVATE_CHANNELS

    # 受信 JSON 文字列を構造化 Result へデコードする
    #
    # @param raw [String] 受信した JSON 文字列(Bitget WS API 仕様準拠)
    # @return [Result::Event, Result::Push, Result::Unknown, Result::ParseError]
    def self.decode(raw)
      parsed = JSON.parse(raw)

      if parsed.is_a?(Hash)
        return decode_event(parsed, raw) if parsed.key?("event")
        return decode_push(parsed, raw) if parsed.key?("action") && parsed.key?("arg") && parsed.key?("data")
      end

      Result::Unknown.new(raw: parsed)
    rescue JSON::ParserError => e
      Result::ParseError.new(raw: raw, error: e)
    end

    def self.decode_event(parsed, raw)
      Result::Event.new(
        event_name: parsed["event"],
        arg: parsed["arg"],
        code: parsed["code"],
        message: parsed["msg"],
        raw: raw
      )
    end
    private_class_method :decode_event

    def self.decode_push(parsed, raw)
      Result::Push.new(
        action: parsed["action"],
        arg: parsed["arg"],
        data: parsed["data"],
        ts: parsed["ts"],
        raw: raw
      )
    end
    private_class_method :decode_push

    # Decode 結果の基底クラス。共通の述語メソッドは全て false を返し,
    # 各サブクラスで該当の述語のみ true でオーバーライドする。
    class Result
      def event?;       false; end
      def push?;        false; end
      def unknown?;     false; end
      def parse_error?; false; end

      # subscribe / unsubscribe / error / login 等のイベントメッセージ
      class Event < Result
        attr_reader :event_name, :arg, :code, :message, :raw

        def initialize(event_name:, arg:, raw:, code: nil, message: nil)
          super()
          @event_name = event_name
          @arg = arg
          @code = code
          @message = message
          @raw = raw
        end

        def event?
          true
        end

        # error イベント(Public/Private 共通)
        def error?
          event_name == "error" || (event_name == "login" && code != 0)
        end

        # login 成功(Private 固有)
        # event=login かつ code=0 を成功と判定
        def login_success?
          event_name == "login" && code == 0
        end
      end

      # snapshot / update のデータ push メッセージ
      class Push < Result
        # orders-algo の state フィールドによる状態別判定マップ
        # Bitget API 仕様: live = 発注成功 / executed = トリガー到達 / canceled = キャンセル
        ALGO_STATES = {
          create: %w[live not_trigger plan_started].freeze,
          triggered: %w[executed effective].freeze,
          cancelled: %w[canceled cancel_failed].freeze
        }.freeze

        private_constant :ALGO_STATES

        attr_reader :action, :arg, :data, :ts, :raw

        def initialize(action:, arg:, data:, ts:, raw:)
          super()
          @action = action
          @arg = arg
          @data = data
          @ts = ts
          @raw = raw
        end

        def push?
          true
        end

        def snapshot?
          action == "snapshot"
        end

        def update?
          action == "update"
        end

        # チャネル名取得
        def channel
          arg&.fetch("channel", nil)
        end

        # チャネル別述語(Bitget Private WS の 6 チャネル)
        def orders?;            channel == "orders"; end
        def orders_algo?;       channel == "orders-algo"; end
        def fill?;              channel == "fill"; end
        def positions?;         channel == "positions"; end
        def positions_history?; channel == "positions-history"; end
        def account?;           channel == "account"; end

        # orders-algo の状態別述語(設計書 05_§3.6 + 02_§4.2.3 反映)
        # data 配列内の最初の entry の "state" フィールドで判定
        # 複数 entry がある場合は呼出側で各 entry を個別判定する責務
        def algo_create?
          orders_algo? && ALGO_STATES[:create].include?(first_algo_state)
        end

        def algo_triggered?
          orders_algo? && ALGO_STATES[:triggered].include?(first_algo_state)
        end

        def algo_cancelled?
          orders_algo? && ALGO_STATES[:cancelled].include?(first_algo_state)
        end

        # 上記 3 種いずれにも該当しない異常状態(設計書 05_§3.6: アラート + reconciliation 起動)
        def algo_anomaly?
          orders_algo? && !algo_create? && !algo_triggered? && !algo_cancelled?
        end

        private

        def first_algo_state
          return nil unless data.is_a?(Array) && data.first.is_a?(Hash)

          data.first["state"]
        end
      end

      # event / action どちらも持たない予期しないメッセージ
      class Unknown < Result
        attr_reader :raw

        def initialize(raw:)
          super()
          @raw = raw
        end

        def unknown?
          true
        end
      end

      # JSON パース失敗
      class ParseError < Result
        attr_reader :raw, :error

        def initialize(raw:, error:)
          super()
          @raw = raw
          @error = error
        end

        def parse_error?
          true
        end
      end
    end
    private_constant :Result
  end
end
