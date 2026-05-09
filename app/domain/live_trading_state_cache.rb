require "bigdecimal"

module Domain
  # ライブトレードの balance / position を memory cache する Domain サービス.
  #
  # Phase 3.4-pre R-8-5 で Worker 責務肥大化(D-1 / D-2)解消のため抽出した.
  # 元: LiveTradingWorker 内 @cached_balance / @cached_position / @cached_state_mutex +
  #     update_cached_balance_from_push / update_cached_position_from_push / parse_big_decimal.
  #
  # 責務:
  #   - balance / position の memory cache 保持(thread-safe / Mutex 保護)
  #   - WS push データから cache を更新する apply_*_push メソッド群
  #   - snapshot で 1 ロック内に [balance, position] を整合性持って取得
  #   - direct update メソッド(initial fetch 用 / Bitget API レスポンスから値設定)
  #
  # MVP 動作:
  #   - 初期値: balance=0 / position=no-position(side=nil / size=0 / entry=0)
  #   - bootstrap: Worker が account_endpoint.account を呼んで update_balance で初期値設定
  #   - WS push: apply_account_push / apply_position_push で動的更新
  #   - 戦略 evaluate: snapshot で [balance, position] を取得して ctx_input / RiskGuard に渡す
  class LiveTradingStateCache
    ALLOWED_POSITION_SIDES = %w[long short].freeze

    private_constant :ALLOWED_POSITION_SIDES

    # @param logger [Logger] 入力バリデーション失敗時の警告出力先
    def initialize(logger: Rails.logger)
      @logger = logger
      @balance = BigDecimal("0")
      @position = Domain::PositionValueObject.new
      @mutex = Mutex.new
    end

    # cache の現在値を 1 ロック内で取得(整合性保証).
    #
    # @return [Array(BigDecimal, Domain::PositionValueObject)]
    def snapshot
      @mutex.synchronize { [ @balance, @position ] }
    end

    # @return [BigDecimal] 現在の balance(thread-safe read)
    def balance
      @mutex.synchronize { @balance }
    end

    # @return [Domain::PositionValueObject] 現在の position(thread-safe read)
    def position
      @mutex.synchronize { @position }
    end

    # balance を直接更新する(bootstrap initial fetch 用).
    # nil / 不正値の場合は cache 不変.
    #
    # @param value [String, Numeric, nil] BigDecimal 化可能な balance 値
    # @return [BigDecimal, nil] 更新成功時は新値 / 失敗時 nil
    def update_balance(value)
      parsed = parse_big_decimal(value)
      return nil if parsed.nil?

      @mutex.synchronize { @balance = parsed }
      parsed
    end

    # account WS push の最新 row から margin_coin に該当する row の available 値で balance を更新する.
    # data 形式: [{"marginCoin": "USDT", "available": "1000.0", "frozen": "0.0", ...}, ...]
    #
    # @param data [Array<Hash>, nil] WS push の data 部分
    # @param margin_coin [String] 反映対象の margin_coin(該当 row のみ反映)
    # @return [BigDecimal, nil] 更新成功時は新値 / data 形式不正 / 該当 row なし / parse 失敗時は nil
    def apply_account_push(data, margin_coin:)
      return nil unless data.is_a?(Array)

      row = data.find { |r| r.is_a?(Hash) && r["marginCoin"] == margin_coin }
      return nil unless row

      update_balance(row["available"])
    rescue StandardError => e
      logger.warn(
        "[LiveTradingStateCache] apply_account_push failed: " \
        "#{e.class.name}: #{Domain::FailureReasonSanitizer.sanitize(e.message)}"
      )
      nil
    end

    # positions WS push の最新 row から symbol に該当する row で position を更新する.
    # data 形式: [{"symbol": "BTCUSDT", "holdSide": "long"|"short", "total": "0.05", "openPriceAvg": "50000", ...}, ...]
    # holdSide が `long` / `short` 以外の場合は cache 不変 + warn(silent failure 防止).
    # total / openPriceAvg が nil / 不正値の場合も cache 不変.
    #
    # @param data [Array<Hash>, nil] WS push の data 部分
    # @param symbol [String] 反映対象の symbol(該当 row のみ反映)
    # @return [Domain::PositionValueObject, nil] 更新成功時は新 position / 失敗時 nil
    def apply_position_push(data, symbol:)
      return nil unless data.is_a?(Array)

      row = data.find { |r| r.is_a?(Hash) && r["symbol"] == symbol }
      return nil unless row

      side_str = row["holdSide"]
      unless ALLOWED_POSITION_SIDES.include?(side_str)
        logger.warn(
          "[LiveTradingStateCache] apply_position_push: " \
          "unknown holdSide=#{side_str.inspect} (cache unchanged)"
        )
        return nil
      end

      size = parse_big_decimal(row["total"])
      entry = parse_big_decimal(row["openPriceAvg"])
      return nil if size.nil? || entry.nil?

      # close 完了直後の Bitget push は size=0 で来ることがある.
      # その場合は flat VO(side=nil / size=0 / entry=0)に正規化し
      # `side: :long, size: 0` のような曖昧な VO を持たない.
      new_position =
        if size.zero?
          Domain::PositionValueObject.new
        else
          Domain::PositionValueObject.new(side: side_str.to_sym, size: size, entry_price: entry)
        end
      @mutex.synchronize { @position = new_position }
      new_position
    rescue StandardError => e
      logger.warn(
        "[LiveTradingStateCache] apply_position_push failed: " \
        "#{e.class.name}: #{Domain::FailureReasonSanitizer.sanitize(e.message)}"
      )
      nil
    end

    private

    attr_reader :logger

    # BigDecimal の nil / 空文字列 / 不正値ガード共通 helper.
    # 返り値 nil で「parse 不可」を表現し,呼出側で cache 更新 skip を判定する.
    def parse_big_decimal(value)
      return nil if value.nil?

      str = value.to_s
      return nil if str.empty?

      BigDecimal(str)
    rescue ArgumentError
      nil
    end
  end
end
