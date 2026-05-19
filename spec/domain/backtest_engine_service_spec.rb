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
      "errors" => [ { "class" => error_class, "message" => message } ],
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
          ipc_ok(order_intents: [ { "side" => "long", "size" => "1.0", "order_type" => "market" } ]),
          ipc_ok(order_intents: [ { "side" => "close", "size" => "0", "order_type" => "market" } ])
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
          ipc_ok(order_intents: [ {
            "side" => "long",
            "size" => "1.0",
            "order_type" => "limit",
            "limit_price" => "98"
          } ])
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
          ipc_ok(order_intents: [ {
            "side" => "long",
            "size" => "1.0",
            "order_type" => "limit",
            "limit_price" => "80"
          } ])
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
          ipc_ok(state_diff_ops: [ { "op" => "replace_all", "value" => { "counter" => 5 } } ]),
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
          received_states.size == 1 ? ipc_ok(state_diff_ops: [ { "op" => "replace_all", "value" => { "counter" => 5 } } ]) : ipc_ok
        end
        subject
        expect(received_states[0]).to eq({})
        expect(received_states[1]).to eq({ "counter" => 5 })
      end
    end

    context "spawner が status=error を返す場合" do
      let(:candles) do
        [ candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 100, low: 100, close: 100) ]
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
        [ candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 100, low: 100, close: 100) ]
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
      let(:candles) { [ candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 100, low: 100, close: 100) ] }
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

    context "成行 long エントリー後に candle が TP 価格へ到達した場合" do
      let(:candles) do
        [
          candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 100, low: 100, close: 100),
          candle(ts: Time.utc(2026, 1, 1, 1), open: 110, high: 115, low: 105, close: 110)
        ]
      end

      before do
        allow(spawner).to receive(:run).and_return(
          ipc_ok(order_intents: [ {
            "side" => "long", "size" => "1.0", "order_type" => "market",
            "tp_pct" => "0.02", "sl_pct" => "0.01"
          } ]),
          ipc_ok
        )
      end

      subject do
        engine.run(
          strategy_revision: revision, risk_policy: risk_policy, candles: candles,
          fee_rate: fee_rate, slippage_rate: slippage_rate
        )
      end

      it "TP 価格(slippage 適用)で自動決済され trade が 1 件生成される" do
        result = subject
        expect(result[:trades].size).to eq(1)
        trade = result[:trades].first
        entry_fill = BigDecimal("100") * (BigDecimal("1") + slippage_rate)
        tp_price = entry_fill * (BigDecimal("1") + BigDecimal("0.02"))
        expect(trade[:side]).to eq("long")
        expect(trade[:entry_price]).to eq(entry_fill)
        expect(trade[:exit_price]).to eq(tp_price * (BigDecimal("1") - slippage_rate))
        expect(trade[:exit_at]).to eq(Time.utc(2026, 1, 1, 1))
      end
    end

    context "成行 long エントリー後に candle が SL 価格へ到達した場合" do
      let(:candles) do
        [
          candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 100, low: 100, close: 100),
          candle(ts: Time.utc(2026, 1, 1, 1), open: 95, high: 100, low: 90, close: 95)
        ]
      end

      before do
        allow(spawner).to receive(:run).and_return(
          ipc_ok(order_intents: [ {
            "side" => "long", "size" => "1.0", "order_type" => "market",
            "tp_pct" => "0.02", "sl_pct" => "0.01"
          } ]),
          ipc_ok
        )
      end

      subject do
        engine.run(
          strategy_revision: revision, risk_policy: risk_policy, candles: candles,
          fee_rate: fee_rate, slippage_rate: slippage_rate
        )
      end

      it "SL 価格(slippage 適用)で自動決済され trade が 1 件生成される" do
        result = subject
        expect(result[:trades].size).to eq(1)
        trade = result[:trades].first
        entry_fill = BigDecimal("100") * (BigDecimal("1") + slippage_rate)
        sl_price = entry_fill * (BigDecimal("1") - BigDecimal("0.01"))
        expect(trade[:exit_price]).to eq(sl_price * (BigDecimal("1") - slippage_rate))
      end
    end

    context "成行 short エントリー後に candle が SL 価格へ到達した場合" do
      let(:candles) do
        [
          candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 100, low: 100, close: 100),
          candle(ts: Time.utc(2026, 1, 1, 1), open: 105, high: 110, low: 100, close: 105)
        ]
      end

      before do
        allow(spawner).to receive(:run).and_return(
          ipc_ok(order_intents: [ {
            "side" => "short", "size" => "1.0", "order_type" => "market",
            "tp_pct" => "0.02", "sl_pct" => "0.01"
          } ]),
          ipc_ok
        )
      end

      subject do
        engine.run(
          strategy_revision: revision, risk_policy: risk_policy, candles: candles,
          fee_rate: fee_rate, slippage_rate: slippage_rate
        )
      end

      it "SL 価格(slippage 適用)で自動決済され trade が 1 件生成される" do
        result = subject
        expect(result[:trades].size).to eq(1)
        trade = result[:trades].first
        # short エントリー fill は close - slippage
        entry_fill = BigDecimal("100") * (BigDecimal("1") - slippage_rate)
        # short の SL は entry * (1 + sl_pct)
        sl_price = entry_fill * (BigDecimal("1") + BigDecimal("0.01"))
        expect(trade[:side]).to eq("short")
        # short の close slippage は close + slippage
        expect(trade[:exit_price]).to eq(sl_price * (BigDecimal("1") + slippage_rate))
      end
    end

    context "同一 candle で TP 価格と SL 価格の両方を跨いだ場合" do
      let(:candles) do
        [
          candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 100, low: 100, close: 100),
          candle(ts: Time.utc(2026, 1, 1, 1), open: 110, high: 115, low: 90, close: 110)
        ]
      end

      before do
        allow(spawner).to receive(:run).and_return(
          ipc_ok(order_intents: [ {
            "side" => "long", "size" => "1.0", "order_type" => "market",
            "tp_pct" => "0.02", "sl_pct" => "0.01"
          } ]),
          ipc_ok
        )
      end

      subject do
        engine.run(
          strategy_revision: revision, risk_policy: risk_policy, candles: candles,
          fee_rate: fee_rate, slippage_rate: slippage_rate
        )
      end

      it "SL 優先で決済される(保守的処理)" do
        result = subject
        expect(result[:trades].size).to eq(1)
        trade = result[:trades].first
        entry_fill = BigDecimal("100") * (BigDecimal("1") + slippage_rate)
        sl_price = entry_fill * (BigDecimal("1") - BigDecimal("0.01"))
        expect(trade[:exit_price]).to eq(sl_price * (BigDecimal("1") - slippage_rate))
      end
    end

    context "エントリーした candle 内で即座に TP/SL を両跨ぎした場合" do
      let(:candles) do
        [ candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 200, low: 50, close: 100) ]
      end

      before do
        allow(spawner).to receive(:run).and_return(
          ipc_ok(order_intents: [ {
            "side" => "long", "size" => "1.0", "order_type" => "market",
            "tp_pct" => "0.02", "sl_pct" => "0.01"
          } ])
        )
      end

      subject do
        engine.run(
          strategy_revision: revision, risk_policy: risk_policy, candles: candles,
          fee_rate: fee_rate, slippage_rate: slippage_rate
        )
      end

      it "エントリー candle で SL 優先決済され trade が 1 件生成される" do
        result = subject
        expect(result[:trades].size).to eq(1)
        expect(result[:trades].first[:exit_at]).to eq(Time.utc(2026, 1, 1, 0))
      end
    end

    context "tp_pct / sl_pct が未設定のエントリーで candle が価格変動した場合" do
      let(:candles) do
        [
          candle(ts: Time.utc(2026, 1, 1, 0), open: 100, high: 100, low: 100, close: 100),
          candle(ts: Time.utc(2026, 1, 1, 1), open: 110, high: 200, low: 50, close: 110)
        ]
      end

      before do
        allow(spawner).to receive(:run).and_return(
          ipc_ok(order_intents: [ { "side" => "long", "size" => "1.0", "order_type" => "market" } ]),
          ipc_ok
        )
      end

      subject do
        engine.run(
          strategy_revision: revision, risk_policy: risk_policy, candles: candles,
          fee_rate: fee_rate, slippage_rate: slippage_rate
        )
      end

      it "TP/SL 自動決済は行われず trade が生成されない" do
        result = subject
        expect(result[:trades]).to be_empty
      end
    end
  end

  describe "#apply_state_diff(軽微追加 B: fail-fast 異常系)" do
    let(:engine) { described_class.new(spawner: spawner) }

    context "未対応 op を含む diff を受信した場合" do
      let(:diff) { { "ops" => [ { "op" => "set", "path" => "key", "value" => 1 } ] } }

      it "ArgumentError を raise する(silent ignore 禁止)" do
        expect { engine.send(:apply_state_diff, {}, diff) }
          .to raise_error(ArgumentError, /unsupported strategy_state_diff op/)
      end
    end

    context "ops が空配列または nil または diff 自体が nil の場合" do
      it "ArgumentError を raise せず元の state を返す" do
        expect(engine.send(:apply_state_diff, { "x" => 1 }, nil)).to eq({ "x" => 1 })
        expect(engine.send(:apply_state_diff, { "x" => 1 }, { "ops" => [] })).to eq({ "x" => 1 })
        expect(engine.send(:apply_state_diff, { "x" => 1 }, { "ops" => nil })).to eq({ "x" => 1 })
      end
    end
  end
end
