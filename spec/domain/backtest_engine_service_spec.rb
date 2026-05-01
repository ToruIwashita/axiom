require "rails_helper"

RSpec.describe Domain::BacktestEngineService do
  let(:definition) do
    Strategy::Definition.create!(name: "BE Strat", market_type: "futures", status: "active")
  end
  let(:script_body) do
    <<~RUBY
      class Sample < Domain::TradingScriptBase
        def on_tick(ctx, candle); end
      end
    RUBY
  end
  let(:revision) do
    Strategy::Revision.create!(
      strategy_definition: definition,
      revision_number: 1,
      script_content: script_body,
      script_entrypoint: "Sample",
      status: "approved",
      ast_validation_status: "passed",
      uses_live_forbidden_input: false,
      ai_filter_enabled: false,
      ai_sizing_enabled: false
    )
  end
  let(:risk_policy) do
    Risk::Policy.create!(
      name: "BE Policy",
      max_drawdown_pct: BigDecimal("20"),
      consecutive_loss_limit: 5,
      max_position_exposure_usdt: BigDecimal("1000"),
      max_leverage: 10,
      cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end

  let(:fee_rate) { BigDecimal("0.001") }
  let(:slippage_rate) { BigDecimal("0.0005") }

  def candle(ts:, open:, high:, low:, close:)
    {
      "ts" => ts,
      "open" => open.to_s,
      "high" => high.to_s,
      "low" => low.to_s,
      "close" => close.to_s
    }
  end

  def ipc_ok(order_intents: [], state_diff_ops: [])
    {
      "schema_version" => "1.0",
      "callback" => "on_tick",
      "status" => "ok",
      "order_intents" => order_intents,
      "logs" => [],
      "errors" => [],
      "strategy_state_diff" => { "ops" => state_diff_ops }
    }
  end

  def ipc_error(error_class: "TimeoutError", message: "boom")
    {
      "schema_version" => "1.0",
      "callback" => "on_tick",
      "status" => "error",
      "order_intents" => [],
      "logs" => [],
      "errors" => [{ "class" => error_class, "message" => message }],
      "strategy_state_diff" => { "ops" => [] }
    }
  end

  let(:spawner) { instance_double(Infrastructure::StrategyRunnerChildSpawner) }
  let(:engine) { described_class.new(spawner: spawner) }

  describe "#run" do
    context "順次 candle で全て status=ok を返し order_intents が空の場合" do
      let(:candles) do
        [
          candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 101, low: 99, close: 100),
          candle(ts: Time.utc(2026, 1, 1, 1), open: 100, high: 102, low: 98, close: 101)
        ]
      end

      before { allow(spawner).to receive(:run).and_return(ipc_ok) }

      subject do
        engine.run(
          strategy_revision: revision,
          risk_policy: risk_policy,
          candles: candles,
          fee_rate: fee_rate,
          slippage_rate: slippage_rate
        )
      end

      it "trades / metrics / equity_curve を含む Hash を返す" do
        result = subject
        expect(result).to be_a(Hash)
        expect(result.keys).to contain_exactly(:trades, :metrics, :equity_curve)
        expect(result[:trades]).to be_an(Array)
        expect(result[:metrics]).to be_a(Domain::PnLMetricsValueObject)
        expect(result[:equity_curve]).to be_an(Array)
        expect(result[:equity_curve].size).to eq(2)
      end

      it "全 candle に対して spawner#run が on_tick で呼ばれる" do
        expect(spawner).to receive(:run).with(callback: :on_tick, revision: revision, ctx_input: instance_of(Hash)).twice.and_return(ipc_ok)
        subject
      end
    end

    context "成行 long entry → close で trade が生成される場合" do
      let(:candles) do
        [
          candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 100, low: 100, close: 100),
          candle(ts: Time.utc(2026, 1, 1, 1), open: 110, high: 110, low: 110, close: 110)
        ]
      end

      before do
        allow(spawner).to receive(:run).and_return(
          ipc_ok(order_intents: [{ "side" => "long", "size" => "1.0", "order_type" => "market" }]),
          ipc_ok(order_intents: [{ "side" => "close", "size" => "0", "order_type" => "market" }])
        )
      end

      subject do
        engine.run(
          strategy_revision: revision,
          risk_policy: risk_policy,
          candles: candles,
          fee_rate: fee_rate,
          slippage_rate: slippage_rate
        )
      end

      it "trade が 1 件生成され entry/exit 価格に slippage が反映される" do
        result = subject
        expect(result[:trades].size).to eq(1)
        trade = result[:trades].first
        expect(trade[:side]).to eq("long")
        expect(trade[:entry_at]).to eq(Time.utc(2026, 1, 1, 0))
        expect(trade[:exit_at]).to eq(Time.utc(2026, 1, 1, 1))
        # entry: 100 * (1 + 0.0005) = 100.05
        expect(trade[:entry_price]).to eq(BigDecimal("100") * (BigDecimal("1") + slippage_rate))
        # exit (long の close 方向は売り): 110 * (1 - 0.0005) = 109.945
        expect(trade[:exit_price]).to eq(BigDecimal("110") * (BigDecimal("1") - slippage_rate))
        expect(trade[:quantity]).to eq(BigDecimal("1.0"))
      end

      it "pnl は (exit_fill - entry_fill) - 両方向 fee で計算される" do
        result = subject
        trade = result[:trades].first
        entry_fill = BigDecimal("100") * (BigDecimal("1") + slippage_rate)
        exit_fill = BigDecimal("110") * (BigDecimal("1") - slippage_rate)
        gross = exit_fill - entry_fill
        # close_position 内では entry_fee も entry_fill(slippage 適用済価格)を基準に算出される
        entry_fee = BigDecimal("1.0") * entry_fill * fee_rate
        exit_fee = BigDecimal("1.0") * exit_fill * fee_rate
        expect(trade[:pnl]).to be_a(BigDecimal)
        expect(trade[:pnl]).to eq(BigDecimal("1.0") * gross - entry_fee - exit_fee)
      end
    end

    context "指値注文が candle 期間の low-high に到達する場合" do
      let(:candles) do
        [
          candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 105, low: 95, close: 100)
        ]
      end

      before do
        allow(spawner).to receive(:run).and_return(
          ipc_ok(order_intents: [{
            "side" => "long",
            "size" => "1.0",
            "order_type" => "limit",
            "limit_price" => "98"
          }])
        )
      end

      subject do
        engine.run(
          strategy_revision: revision,
          risk_policy: risk_policy,
          candles: candles,
          fee_rate: fee_rate,
          slippage_rate: slippage_rate
        )
      end

      it "指値到達なら entry が成立し open_position として保持される" do
        result = subject
        # まだ close していないため trades は 0 件、equity_curve は 1 件
        expect(result[:trades]).to be_empty
        expect(result[:equity_curve].size).to eq(1)
      end
    end

    context "指値注文が candle 期間に到達しない場合" do
      let(:candles) do
        [
          candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 105, low: 95, close: 100)
        ]
      end

      before do
        allow(spawner).to receive(:run).and_return(
          ipc_ok(order_intents: [{
            "side" => "long",
            "size" => "1.0",
            "order_type" => "limit",
            "limit_price" => "80"
          }])
        )
      end

      subject do
        engine.run(
          strategy_revision: revision,
          risk_policy: risk_policy,
          candles: candles,
          fee_rate: fee_rate,
          slippage_rate: slippage_rate
        )
      end

      it "未約定で trades / open_position が増えない" do
        result = subject
        expect(result[:trades]).to be_empty
      end
    end

    context "重要 3: strategy_state_diff replace_all で state 全体置換される場合" do
      let(:candles) do
        [
          candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 100, low: 100, close: 100),
          candle(ts: Time.utc(2026, 1, 1, 1), open: 100, high: 100, low: 100, close: 100)
        ]
      end

      before do
        # 1 candle 目: state を { "counter" => 5 } に置換
        # 2 candle 目: 受信 ctx_input.state が前 candle の置換結果を引き継いでいることを検証
        allow(spawner).to receive(:run).and_return(
          ipc_ok(state_diff_ops: [{ "op" => "replace_all", "value" => { "counter" => 5 } }]),
          ipc_ok
        )
      end

      subject do
        engine.run(
          strategy_revision: revision,
          risk_policy: risk_policy,
          candles: candles,
          fee_rate: fee_rate,
          slippage_rate: slippage_rate
        )
      end

      it "2 回目の spawner#run には更新後の state が ctx_input として渡される" do
        received_states = []
        allow(spawner).to receive(:run) do |callback:, revision:, ctx_input:|
          received_states << ctx_input["state"]
          received_states.size == 1 ? ipc_ok(state_diff_ops: [{ "op" => "replace_all", "value" => { "counter" => 5 } }]) : ipc_ok
        end
        subject
        expect(received_states[0]).to eq({})
        expect(received_states[1]).to eq({ "counter" => 5 })
      end
    end

    context "spawner が status=error を返す場合" do
      let(:candles) do
        [candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 100, low: 100, close: 100)]
      end

      before { allow(spawner).to receive(:run).and_return(ipc_error) }

      subject do
        engine.run(
          strategy_revision: revision,
          risk_policy: risk_policy,
          candles: candles,
          fee_rate: fee_rate,
          slippage_rate: slippage_rate
        )
      end

      it "ExecutionError を raise する" do
        expect { subject }.to raise_error(Domain::BacktestEngineService::ExecutionError, /strategy execution failed/)
      end
    end

    context "spawner が status=timeout を返す場合" do
      let(:candles) do
        [candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 100, low: 100, close: 100)]
      end

      before do
        allow(spawner).to receive(:run).and_return(
          ipc_error(error_class: "TimeoutError", message: "timeout").merge("status" => "timeout")
        )
      end

      subject do
        engine.run(
          strategy_revision: revision,
          risk_policy: risk_policy,
          candles: candles,
          fee_rate: fee_rate,
          slippage_rate: slippage_rate
        )
      end

      it "ExecutionError を raise する" do
        expect { subject }.to raise_error(Domain::BacktestEngineService::ExecutionError)
      end
    end

    context "evaluator への委譲" do
      let(:candles) { [candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 100, low: 100, close: 100)] }
      let(:evaluator) { instance_double(Domain::StrategyEvaluatorService) }
      let(:engine) { described_class.new(spawner: spawner, evaluator: evaluator) }
      let(:dummy_metrics) do
        Domain::PnLMetricsValueObject.new(
          win_rate: BigDecimal("0"), total_pnl: BigDecimal("0"), max_drawdown: BigDecimal("0"),
          sharpe_ratio: BigDecimal("0"), sortino_ratio: BigDecimal("0"), volatility: BigDecimal("0"),
          profit_factor: BigDecimal("0"), total_trades: 0, avg_holding_seconds: 0
        )
      end

      before { allow(spawner).to receive(:run).and_return(ipc_ok) }

      subject do
        engine.run(
          strategy_revision: revision,
          risk_policy: risk_policy,
          candles: candles,
          fee_rate: fee_rate,
          slippage_rate: slippage_rate
        )
      end

      it "全 candle 終了後に evaluator#evaluate が trades / equity_curve で呼ばれる" do
        expect(evaluator).to receive(:evaluate).with(trades: [], equity_curve: instance_of(Array)).and_return(dummy_metrics)
        result = subject
        expect(result[:metrics]).to eq(dummy_metrics)
      end
    end
  end
end
