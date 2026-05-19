require "bigdecimal"

module Domain
  # バックテスト本体エンジン
  #
  # 各 candle で BacktestContext.build_ctx_input で ctx_input を生成し、
  # Infrastructure::StrategyRunnerChildSpawner#run で子プロセスに on_tick を実行させる。
  # 戻り値の order_intents を仮想約定処理し、strategy_state_diff を内部 state に
  # マージしながら trades / equity_curve を蓄積する。全 candle 終了後に
  # Domain::StrategyEvaluatorService で metrics を計算する。
  class BacktestEngineService
    DEFAULT_RUNNER_SCRIPT = Rails.root.join("lib/backtest_runner_child.rb").to_s
    DEFAULT_INITIAL_BALANCE = BigDecimal("10000")
    DEFAULT_LAST_CANDLES_WINDOW = 200

    class ExecutionError < StandardError; end

    # @param spawner [Infrastructure::StrategyRunnerChildSpawner, nil]
    # @param evaluator [Domain::StrategyEvaluatorService, nil]
    # @param initial_balance [BigDecimal] 初期残高
    # @param last_candles_window [Integer] last_candles で渡す履歴本数
    def initialize(spawner: nil, evaluator: nil,
                   initial_balance: DEFAULT_INITIAL_BALANCE,
                   last_candles_window: DEFAULT_LAST_CANDLES_WINDOW)
      @spawner = spawner || Infrastructure::StrategyRunnerChildSpawner.new(runner_script_path: DEFAULT_RUNNER_SCRIPT)
      @evaluator = evaluator || Domain::StrategyEvaluatorService.new
      @initial_balance = initial_balance
      @last_candles_window = last_candles_window
    end

    # バックテストを実行する
    #
    # @param strategy_revision [Strategy::Revision] 実行対象 Revision
    # @param risk_policy [Risk::Policy] 適用リスクポリシー(現状参照のみ)
    # @param candles [Array<Hash>] {ts, open, high, low, close, ...} の配列
    # @param funding_rates [Array<Hash>, nil]
    # @param mark_candles [Array<Hash>, nil]
    # @param index_candles [Array<Hash>, nil]
    # @param spot_candles [Array<Hash>, nil]
    # @param fee_rate [BigDecimal]
    # @param slippage_rate [BigDecimal]
    # @return [Hash] { trades: Array<Hash>, metrics: Domain::PnLMetricsValueObject, equity_curve: Array<Hash> }
    # @raise [ExecutionError] 子プロセス IPC が timeout/error を返した場合
    def run(strategy_revision:, risk_policy:, candles:, funding_rates: nil,
            mark_candles: nil, index_candles: nil, spot_candles: nil,
            fee_rate:, slippage_rate:)
      state = {}
      position = Domain::PositionValueObject.new
      balance = initial_balance
      trades = []
      equity_curve = []
      candle_history = []
      open_position = nil

      candles.each do |candle|
        candle_history << candle
        candle_history.shift if candle_history.size > last_candles_window

        ctx_input = build_ctx_input_for(
          candle:, position:, balance:, state:,
          funding_rates:, mark_candles:, spot_candles:,
          candle_history:
        )

        result = spawner.run(callback: :on_tick, revision: strategy_revision, ctx_input: ctx_input)

        case result["status"]
        when "ok"
          state = apply_state_diff(state, result["strategy_state_diff"])
          result["order_intents"].each do |intent_hash|
            intent = Domain::OrderIntentValueObject.from_h(intent_hash)
            position, balance, open_position, closed_trade = execute_intent(
              intent:, candle:, fee_rate:, slippage_rate:,
              position:, balance:, open_position:
            )
            trades << closed_trade if closed_trade
          end

          # intent 処理後に open_position が残っていれば,当該 candle で TP/SL を跨いだか評価する
          # (エントリーした candle 内での即時 TP/SL 跨ぎも同じ経路で扱う)。
          if open_position
            tp_sl_exit = check_tp_sl_exit(
              open_position:, candle:, fee_rate:, slippage_rate:, balance:
            )
            if tp_sl_exit
              position, balance, open_position, tp_sl_trade = tp_sl_exit
              trades << tp_sl_trade
            end
          end
        when "timeout", "error"
          first_error = (result["errors"] || []).first
          raise ExecutionError, "strategy execution failed: #{first_error.inspect}"
        end

        equity_curve << build_equity_point(
          candle:, balance:, position:,
          peak_equity: equity_curve.map { |p| p[:equity] }.max || initial_balance
        )
      end

      metrics = evaluator.evaluate(trades: trades, equity_curve: equity_curve)
      { trades:, metrics:, equity_curve: }
    end

    private

    attr_reader :spawner, :evaluator, :initial_balance, :last_candles_window

    def build_ctx_input_for(candle:, position:, balance:, state:,
                            funding_rates:, mark_candles:, spot_candles:,
                            candle_history:)
      Domain::BacktestContext.build_ctx_input(
        candle: candle,
        position: position,
        balance: balance,
        state: state,
        funding_rate: funding_rate_at(funding_rates, candle["ts"]),
        mark_basis: basis_at(mark_candles, candle),
        spot_basis: basis_at(spot_candles, candle),
        last_candles: candle_history.dup
      )
    end

    # 重要 3 案 Z: 子から返却された strategy_state_diff を state に適用する。
    # MVP では replace_all(state 全体置換)のみサポート。Phase 3 で set / delete 等の
    # JSON Patch 風差分演算を追加判断する。
    #
    # 軽微追加 B 対応: 未対応 op は fail-fast(silent ignore 禁止)。子側プロトコル不一致を
    # 早期検出するため ArgumentError を raise する。
    def apply_state_diff(state, diff)
      return state if diff.nil? || diff["ops"].nil? || diff["ops"].empty?

      diff["ops"].each do |op|
        case op["op"]
        when "replace_all"
          state = op["value"] || {}
        else
          raise ArgumentError, "unsupported strategy_state_diff op: #{op["op"].inspect}"
        end
      end
      state
    end

    # 仮想約定実行(成行/指値、fee + slippage 適用)。
    #
    # @return [Array(PositionValueObject, BigDecimal, Hash|nil, Hash|nil)]
    #   [position, balance, open_position, closed_trade]
    def execute_intent(intent:, candle:, fee_rate:, slippage_rate:, position:, balance:, open_position:)
      close_price = BigDecimal(candle["close"].to_s)

      if intent.side == :close
        return [ position, balance, open_position, nil ] unless open_position

        return close_position(
          close_price: close_price, candle: candle,
          fee_rate: fee_rate, slippage_rate: slippage_rate,
          balance: balance, open_position: open_position
        )
      end

      # MVP: 1 ポジ運用(既ポジあれば追加 entry を無視)
      return [ position, balance, open_position, nil ] if open_position

      fill_price = calc_fill_price(intent: intent, candle: candle, slippage_rate: slippage_rate, close_price: close_price)
      return [ position, balance, open_position, nil ] if fill_price.nil?

      fee = intent.size * fill_price * fee_rate
      new_balance = balance - fee
      new_position = Domain::PositionValueObject.new(
        side: intent.side, size: intent.size, entry_price: fill_price
      )
      new_open = {
        side: intent.side, size: intent.size, entry_price: fill_price, entry_at: candle["ts"],
        tp_pct: intent.tp_pct, sl_pct: intent.sl_pct
      }
      [ new_position, new_balance, new_open, nil ]
    end

    def calc_fill_price(intent:, candle:, slippage_rate:, close_price:)
      if intent.market?
        slippage_sign = intent.side == :long ? 1 : -1
        close_price + (close_price * slippage_rate * slippage_sign)
      else
        low = BigDecimal(candle["low"].to_s)
        high = BigDecimal(candle["high"].to_s)
        return nil unless (low..high).cover?(intent.limit_price)

        intent.limit_price
      end
    end

    def close_position(close_price:, candle:, fee_rate:, slippage_rate:, balance:, open_position:)
      side = open_position[:side]
      size = open_position[:size]
      entry_price = open_position[:entry_price]
      slippage_sign = side == :long ? -1 : 1
      exit_fill = close_price + (close_price * slippage_rate * slippage_sign)
      diff = side == :long ? (exit_fill - entry_price) : (entry_price - exit_fill)
      gross_pnl = size * diff
      entry_fee = size * entry_price * fee_rate
      exit_fee = size * exit_fill * fee_rate
      net_pnl = gross_pnl - entry_fee - exit_fee
      new_balance = balance + net_pnl

      trade = {
        side: side.to_s,
        entry_at: open_position[:entry_at],
        exit_at: candle["ts"],
        entry_price: entry_price,
        exit_price: exit_fill,
        quantity: size,
        pnl: net_pnl
      }
      [ Domain::PositionValueObject.new, new_balance, nil, trade ]
    end

    # candle が open_position の TP / SL 価格を跨いだ場合に自動決済する。
    # 両跨ぎ時は SL 優先(保守的 / バックテストの楽観バイアス排除)。
    # tp_pct / sl_pct が共に未設定の open_position は評価対象外。
    #
    # @return [Array(PositionValueObject, BigDecimal, nil, Hash), nil]
    #   決済された場合は close_position と同形式の戻り値,跨ぎなしは nil
    def check_tp_sl_exit(open_position:, candle:, fee_rate:, slippage_rate:, balance:)
      exit_price = tp_sl_exit_price(open_position, candle)
      return nil if exit_price.nil?

      close_position(
        close_price: exit_price, candle:, fee_rate:, slippage_rate:,
        balance:, open_position:
      )
    end

    # open_position の TP / SL 価格を candle の high / low が跨いだか判定し,
    # 跨いだ場合の決済価格(TP / SL 価格)を返す。両跨ぎは SL 優先。
    def tp_sl_exit_price(open_position, candle)
      tp_pct = open_position[:tp_pct]
      sl_pct = open_position[:sl_pct]
      return nil if tp_pct.nil? && sl_pct.nil?

      side = open_position[:side]
      entry_price = open_position[:entry_price]
      high = BigDecimal(candle["high"].to_s)
      low = BigDecimal(candle["low"].to_s)

      sl_price = sl_pct && stop_loss_calculator.calculate_sl(entry_price:, side:, sl_pct:)
      tp_price = tp_pct && stop_loss_calculator.calculate_tp(entry_price:, side:, tp_pct:)

      return sl_price if sl_price && sl_crossed?(side, sl_price, high, low)
      return tp_price if tp_price && tp_crossed?(side, tp_price, high, low)

      nil
    end

    # SL 価格を candle が跨いだか。long は安値が SL 以下,short は高値が SL 以上。
    def sl_crossed?(side, sl_price, high, low)
      side == :long ? low <= sl_price : high >= sl_price
    end

    # TP 価格を candle が跨いだか。long は高値が TP 以上,short は安値が TP 以下。
    def tp_crossed?(side, tp_price, high, low)
      side == :long ? high >= tp_price : low <= tp_price
    end

    def stop_loss_calculator
      @stop_loss_calculator ||= Domain::StopLossCalculatorService.new
    end

    def build_equity_point(candle:, balance:, position:, peak_equity:)
      close_price = BigDecimal(candle["close"].to_s)
      equity = balance + position.unrealized_pnl(close_price)
      drawdown = peak_equity.zero? ? BigDecimal("0") : ((peak_equity - equity) / peak_equity)
      {
        ts: candle["ts"],
        equity: equity,
        drawdown: drawdown,
        position_size: position.size
      }
    end

    def funding_rate_at(funding_rates, ts)
      return nil if funding_rates.nil? || funding_rates.empty?

      target = funding_rates.reverse.find { |fr| fr["funding_time"] <= ts }
      target && BigDecimal(target["funding_rate"].to_s)
    end

    def basis_at(reference_candles, candle)
      return nil if reference_candles.nil? || reference_candles.empty?

      ref = reference_candles.find { |c| c["ts"] == candle["ts"] }
      return nil unless ref

      BigDecimal(candle["close"].to_s) - BigDecimal(ref["close"].to_s)
    end
  end
end
