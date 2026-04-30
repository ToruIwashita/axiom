module Infrastructure
  # Bitget Public WebSocket から受信した生 JSON 文字列を解析し,
  # `Result::Event` / `Result::Push` / `Result::Unknown` / `Result::ParseError` のいずれかに分類する。
  #
  # 呼び出し側は Result の述語メソッド(`event?` / `push?` / `unknown?` / `parse_error?`)で型分岐する。
  # `Result` クラス階層は `private_constant` で外部から直接参照不可とする。
  class BitgetPublicWsMessageDecoder
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

        def error?
          event_name == "error"
        end
      end

      # snapshot / update のデータ push メッセージ
      class Push < Result
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
