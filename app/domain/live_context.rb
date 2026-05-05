require "bigdecimal"

module Domain
  # ライブトレード時に戦略コードから参照される ctx adapter
  #
  # BacktestContext の Phase 3 兄弟クラス。入力 API は同一だが,以下が本質的に異なる:
  # - 動的・非決定論的(WS push 受信が随時)
  # - state 永続性(LiveTrading::SessionState への永続化を Phase 3.3 で連携)
  # - async API 呼び出し(REST endpoint 経由)
  #
  # MVP 禁止入力(設計書 05_§2.6.1 / レビュー重要 1 反映):
  # - ctx.mark_basis / ctx.spot_basis の 2 メソッドのみ(Mark/Index/Spot
  #   データストリーム取得は MVP で運用コスト過大のため非対応)
  #
  # @note Rails 非依存実装(子プロセスから require_relative で読込可能とするため)
  class LiveContext
    # MVP で live 環境では使用禁止の入力呼出時に raise される例外
    class NotSupportedInLiveError < StandardError; end

    attr_reader :candle, :position, :balance, :state, :funding_rate,
                :last_candles, :order, :order_intents

    # 親プロセス用: 子に渡す ctx_input Hash を生成する
    # BacktestContext と同じキー構造だが mark_basis / spot_basis は含めない
    #
    # @param candle [Hash] 現在 tick の candle
    # @param position [Domain::PositionValueObject] 現実ポジション
    # @param balance [BigDecimal] 現実残高
    # @param state [Hash] 戦略内部状態(JSON serializable)
    # @param funding_rate [BigDecimal, nil]
    # @param last_candles [Array<Hash>] 直近 N 本の candle
    # @return [Hash] ctx_input(子プロセス IPC payload)
    def self.build_ctx_input(candle:, position:, balance:, state:, funding_rate: nil,
                             last_candles: [])
      {
        "candle" => candle,
        "position" => {
          "side" => position.side&.to_s,
          "size" => position.size.to_s,
          "entry_price" => position.entry_price.to_s
        },
        "balance" => balance.to_s,
        "state" => state,
        "funding_rate" => funding_rate&.to_s,
        "last_candles" => last_candles
      }
    end

    # 子プロセス用: ctx_input から LiveContext を再構築する
    #
    # @param ctx_input [Hash] 親から受信した ctx_input
    # @return [Domain::LiveContext]
    def self.from_ctx_input(ctx_input)
      pos = ctx_input["position"]
      new(
        candle: ctx_input["candle"],
        position: Domain::PositionValueObject.new(
          side: pos["side"]&.to_sym,
          size: BigDecimal(pos["size"]),
          entry_price: BigDecimal(pos["entry_price"])
        ),
        balance: BigDecimal(ctx_input["balance"]),
        state: ctx_input["state"] || {},
        funding_rate: ctx_input["funding_rate"] && BigDecimal(ctx_input["funding_rate"]),
        last_candles: ctx_input["last_candles"] || []
      )
    end

    # @param candle [Hash] 現在 tick の candle
    # @param position [Domain::PositionValueObject]
    # @param balance [BigDecimal]
    # @param state [Hash]
    # @param funding_rate [BigDecimal, nil]
    # @param last_candles [Array<Hash>]
    def initialize(candle:, position:, balance:, state:, funding_rate: nil, last_candles: [])
      @candle = candle
      @position = position
      @balance = balance
      @state = state
      @funding_rate = funding_rate
      @last_candles = last_candles
      @order_intents = []
      @order = OrderProxy.new(intents: @order_intents)
    end

    # MVP 禁止入力(設計書 05_§2.6.1)
    #
    # @raise [NotSupportedInLiveError] 必ず raise(MVP では Mark/Index データ取得非対応)
    def mark_basis
      raise NotSupportedInLiveError,
            "ctx.mark_basis is not supported in live environment (MVP). " \
            "See design doc 05_§2.6.1 for details."
    end

    # MVP 禁止入力(設計書 05_§2.6.1)
    #
    # @raise [NotSupportedInLiveError] 必ず raise(MVP では Spot データ取得非対応)
    def spot_basis
      raise NotSupportedInLiveError,
            "ctx.spot_basis is not supported in live environment (MVP). " \
            "See design doc 05_§2.6.1 for details."
    end

    # AI フィルタスタブ(Phase 3.3 で Domain::AiFilterService 経由置換予定)
    #
    # @param template [Symbol, String] テンプレート名(無視される)
    # @param context [Hash] 文脈情報(無視される)
    # @return [Hash] { enter: true, reason: "live stub" }
    def ai_filter(template:, context:)
      { enter: true, reason: "live stub" }
    end

    # 直近 N 本の candle を取得する
    #
    # @param n [Integer] 取得本数
    # @return [Array<Hash>]
    def last_n_candles(n)
      last_candles.last(n)
    end

    # 単純移動平均を計算する(BacktestContext と同じロジック)
    #
    # @param period [Integer] 期間
    # @return [BigDecimal, nil] 計算可能なら BigDecimal,データ不足なら nil
    def sma(period)
      return nil if last_candles.size < period

      sum = last_candles.last(period).sum(BigDecimal("0")) { |c| BigDecimal(c["close"].to_s) }
      sum / BigDecimal(period)
    end

    # RSI を計算する(Wilder の単純平均版,BacktestContext と同じロジック)
    #
    # @param period [Integer] 期間
    # @return [BigDecimal, nil] period+1 本未満は nil,avg_loss=0 なら 100
    def rsi(period)
      return nil if last_candles.size < period + 1

      closes = last_candles.last(period + 1).map { |c| BigDecimal(c["close"].to_s) }
      gains = []
      losses = []
      closes.each_cons(2) do |prev, curr|
        diff = curr - prev
        gains << (diff.positive? ? diff : BigDecimal("0"))
        losses << (diff.negative? ? -diff : BigDecimal("0"))
      end
      avg_gain = gains.sum(BigDecimal("0")) / BigDecimal(period)
      avg_loss = losses.sum(BigDecimal("0")) / BigDecimal(period)
      return BigDecimal("100") if avg_loss.zero?

      rs = avg_gain / avg_loss
      BigDecimal("100") - (BigDecimal("100") / (BigDecimal("1") + rs))
    end

    private

    # 戦略コードから ctx.order.entry(...) / ctx.order.close を呼ぶための proxy
    # BacktestContext::OrderProxy と同等のインターフェース
    class OrderProxy
      def initialize(intents:)
        @intents = intents
      end

      # ロング/ショート発注 intent を記録する
      #
      # @param side [Symbol] :long / :short
      # @param size [Numeric] 数量
      # @param order_type [Symbol] :market / :limit(default :market)
      # @param limit_price [Numeric, nil]
      # @param tp_pct [Numeric, nil]
      # @param sl_pct [Numeric, nil]
      # @return [Hash] 追加された intent Hash
      def entry(side:, size:, order_type: :market, limit_price: nil, tp_pct: nil, sl_pct: nil)
        intent = {
          "side" => side.to_s,
          "size" => size.to_s,
          "order_type" => order_type.to_s,
          "limit_price" => limit_price&.to_s,
          "tp_pct" => tp_pct&.to_s,
          "sl_pct" => sl_pct&.to_s
        }.compact
        @intents << intent
        intent
      end

      # 決済 intent を記録する
      #
      # @return [Hash] 追加された intent Hash
      def close
        intent = { "side" => "close", "size" => "0", "order_type" => "market" }
        @intents << intent
        intent
      end
    end
    private_constant :OrderProxy
  end
end
