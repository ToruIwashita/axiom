require "rails_helper"

RSpec.describe Domain::BacktestContext do
  let(:candle) do
    {
      "ts" => Time.utc(2026, 1, 5, 0, 0, 0),
      "open" => "40000",
      "high" => "40500",
      "low" => "39800",
      "close" => "40200",
      "base_volume" => "10.5",
      "quote_volume" => "421050"
    }
  end
  let(:position) do
    Domain::PositionValueObject.new(side: :long, size: BigDecimal("0.5"), entry_price: BigDecimal("40000"))
  end
  let(:balance) { BigDecimal("10000") }
  let(:state) { { "counter" => 1 } }
  let(:funding_rate) { BigDecimal("0.0001") }
  let(:mark_basis) { BigDecimal("5") }
  let(:spot_basis) { BigDecimal("-2") }
  let(:last_candles) do
    (1..5).map do |i|
      { "ts" => Time.utc(2026, 1, 4, i, 0, 0), "close" => (40000 + i * 100).to_s }
    end
  end

  describe ".build_ctx_input" do
    subject do
      described_class.build_ctx_input(
        candle: candle,
        position: position,
        balance: balance,
        state: state,
        funding_rate: funding_rate,
        mark_basis: mark_basis,
        spot_basis: spot_basis,
        last_candles: last_candles
      )
    end

    context "全 keyword 引数を渡した場合" do
      it "JSON serializable な ctx_input Hash を返す" do
        expect(subject["candle"]).to eq(candle)
        expect(subject["position"]).to eq("side" => "long", "size" => "0.5", "entry_price" => "40000.0")
        expect(subject["balance"]).to eq("10000.0")
        expect(subject["state"]).to eq(state)
        expect(subject["funding_rate"]).to eq("0.0001")
        expect(subject["mark_basis"]).to eq("5.0")
        expect(subject["spot_basis"]).to eq("-2.0")
        expect(subject["last_candles"]).to eq(last_candles)
      end
    end

    context "オプション引数を省略した場合" do
      subject do
        described_class.build_ctx_input(
          candle: candle,
          position: position,
          balance: balance,
          state: state
        )
      end

      it "funding_rate / mark_basis / spot_basis が nil で last_candles が空配列" do
        expect(subject["funding_rate"]).to be_nil
        expect(subject["mark_basis"]).to be_nil
        expect(subject["spot_basis"]).to be_nil
        expect(subject["last_candles"]).to eq([])
      end
    end
  end

  describe ".from_ctx_input" do
    let(:ctx_input) do
      described_class.build_ctx_input(
        candle: candle,
        position: position,
        balance: balance,
        state: state,
        funding_rate: funding_rate,
        mark_basis: mark_basis,
        spot_basis: spot_basis,
        last_candles: last_candles
      )
    end

    subject { described_class.from_ctx_input(ctx_input) }

    context "build_ctx_input で生成された Hash から再構築する場合" do
      it "candle / position / balance / state / 各 basis を復元する" do
        expect(subject.candle).to eq(candle)
        expect(subject.position.side).to eq(:long)
        expect(subject.position.size).to eq(BigDecimal("0.5"))
        expect(subject.position.entry_price).to eq(BigDecimal("40000"))
        expect(subject.balance).to eq(BigDecimal("10000"))
        expect(subject.state).to eq(state)
        expect(subject.funding_rate).to eq(BigDecimal("0.0001"))
        expect(subject.mark_basis).to eq(BigDecimal("5"))
        expect(subject.spot_basis).to eq(BigDecimal("-2"))
        expect(subject.last_candles).to eq(last_candles)
      end
    end
  end

  describe "#ai_filter" do
    subject do
      described_class.new(
        candle: candle, position: position, balance: balance, state: state
      ).ai_filter(template: :stub_template, context: {})
    end

    context "テンプレート / コンテキストを渡した場合(バックテスト時)" do
      it "常時許可スタブ { enter: true, reason: backtest stub } を返す" do
        expect(subject).to eq(enter: true, reason: "backtest stub")
      end
    end
  end

  describe "#last_n_candles" do
    let(:ctx) do
      described_class.new(
        candle: candle, position: position, balance: balance, state: state, last_candles: last_candles
      )
    end

    context "保有 last_candles 数より少ない n を渡した場合" do
      subject { ctx.last_n_candles(3) }

      it "末尾 n 本を返す" do
        expect(subject).to eq(last_candles.last(3))
      end
    end

    context "保有 last_candles 数を超える n を渡した場合" do
      subject { ctx.last_n_candles(100) }

      it "保有分すべてを返す" do
        expect(subject).to eq(last_candles)
      end
    end
  end

  describe "#sma" do
    let(:ctx) do
      described_class.new(
        candle: candle, position: position, balance: balance, state: state, last_candles: last_candles
      )
    end

    context "period が last_candles 件数以下の場合" do
      subject { ctx.sma(3) }

      it "末尾 period 本の close 平均を BigDecimal で返す" do
        last_three_closes = last_candles.last(3).map { |c| BigDecimal(c["close"]) }
        expected = last_three_closes.sum / BigDecimal(3)
        expect(subject).to eq(expected)
      end
    end

    context "period が last_candles 件数を超える場合" do
      subject { ctx.sma(100) }

      it "nil を返す" do
        expect(subject).to be_nil
      end
    end

    # Phase 3.1 レビュー R-6 反映(LiveContext と一貫修正): period=0 / 負値ゼロ除算防衛
    context "period が 0 の場合" do
      it "ArgumentError raise" do
        expect { ctx.sma(0) }.to raise_error(ArgumentError, /period must be >= 1/)
      end
    end

    context "period が負値の場合" do
      it "ArgumentError raise" do
        expect { ctx.sma(-1) }.to raise_error(ArgumentError, /period must be >= 1/)
      end
    end
  end

  describe "#rsi" do
    let(:rising_candles) do
      (1..15).map { |i| { "ts" => Time.utc(2026, 1, 4, i, 0, 0), "close" => (40000 + i * 10).to_s } }
    end
    let(:flat_candles) do
      (1..15).map { |i| { "ts" => Time.utc(2026, 1, 4, i, 0, 0), "close" => "40000" } }
    end

    context "全期間が上昇連続(損失なし)の場合" do
      subject do
        ctx = described_class.new(
          candle: candle, position: position, balance: balance, state: state, last_candles: rising_candles
        )
        ctx.rsi(14)
      end

      it "100 を返す(avg_loss=0 ハンドリング)" do
        expect(subject).to eq(BigDecimal("100"))
      end
    end

    context "period + 1 本未満の場合" do
      subject do
        ctx = described_class.new(
          candle: candle, position: position, balance: balance, state: state, last_candles: rising_candles[0, 5]
        )
        ctx.rsi(14)
      end

      it "nil を返す" do
        expect(subject).to be_nil
      end
    end

    context "全期間が変化なし(gain も loss も 0)の場合" do
      subject do
        ctx = described_class.new(
          candle: candle, position: position, balance: balance, state: state, last_candles: flat_candles
        )
        ctx.rsi(14)
      end

      it "100 を返す(avg_loss=0 ハンドリング)" do
        expect(subject).to eq(BigDecimal("100"))
      end
    end

    # Phase 3.1 レビュー R-6 反映(LiveContext と一貫修正): period=0 / 負値ゼロ除算防衛
    context "period が 0 の場合" do
      subject do
        ctx = described_class.new(
          candle: candle, position: position, balance: balance, state: state, last_candles: rising_candles
        )
        ctx.rsi(0)
      end

      it "ArgumentError raise" do
        expect { subject }.to raise_error(ArgumentError, /period must be >= 1/)
      end
    end

    context "period が負値の場合" do
      subject do
        ctx = described_class.new(
          candle: candle, position: position, balance: balance, state: state, last_candles: rising_candles
        )
        ctx.rsi(-1)
      end

      it "ArgumentError raise" do
        expect { subject }.to raise_error(ArgumentError, /period must be >= 1/)
      end
    end
  end

  describe "ctx.order.entry / ctx.order.close" do
    let(:ctx) do
      described_class.new(
        candle: candle, position: position, balance: balance, state: state
      )
    end

    context "ctx.order.entry でロング成行を記録する場合" do
      subject { ctx.order.entry(side: :long, size: 1.0) }

      it "order_intents に成行 long Hash が追加される" do
        subject
        expect(ctx.order_intents.size).to eq(1)
        expect(ctx.order_intents.first).to include("side" => "long", "size" => "1.0", "order_type" => "market")
      end
    end

    context "ctx.order.entry で指値ショート + tp_pct/sl_pct を記録する場合" do
      subject do
        ctx.order.entry(
          side: :short,
          size: 0.5,
          order_type: :limit,
          limit_price: 40500,
          tp_pct: 0.02,
          sl_pct: 0.01
        )
      end

      it "order_intents に limit short + tp/sl が追加される" do
        subject
        intent = ctx.order_intents.first
        expect(intent).to include(
          "side" => "short",
          "size" => "0.5",
          "order_type" => "limit",
          "limit_price" => "40500",
          "tp_pct" => "0.02",
          "sl_pct" => "0.01"
        )
      end
    end

    context "ctx.order.close で決済 intent を記録する場合" do
      subject { ctx.order.close }

      it "order_intents に close intent が追加される" do
        subject
        expect(ctx.order_intents.first).to include("side" => "close", "size" => "0", "order_type" => "market")
      end
    end

    context "複数 intent を記録した場合" do
      subject do
        ctx.order.entry(side: :long, size: 1.0)
        ctx.order.close
      end

      it "order_intents に 2 件追加される" do
        subject
        expect(ctx.order_intents.size).to eq(2)
      end
    end
  end

  describe "order_intents の可視性(軽微追加 C)" do
    let(:ctx) do
      described_class.new(
        candle: candle, position: position, balance: balance, state: state
      )
    end

    context "public attr_reader 単独定義の場合" do
      it "ctx.order_intents が呼び出し可能で初期値が空配列" do
        expect(ctx.order_intents).to eq([])
      end

      it "ctx.order_intents= setter は定義されていない" do
        expect(ctx.respond_to?(:order_intents=)).to be false
      end
    end
  end
end
