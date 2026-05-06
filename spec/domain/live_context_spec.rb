require "rails_helper"

RSpec.describe Domain::LiveContext do
  let(:position) do
    Domain::PositionValueObject.new(
      side: :long,
      size: BigDecimal("0.01"),
      entry_price: BigDecimal("50000")
    )
  end
  let(:base_attributes) do
    {
      candle: { "ts" => Time.utc(2026, 5, 5, 12, 0, 0).iso8601, "close" => "50000" },
      position: position,
      balance: BigDecimal("10000"),
      state: { "counter" => 0 },
      funding_rate: BigDecimal("0.0001"),
      last_candles: []
    }
  end

  describe ".build_ctx_input" do
    subject { described_class.build_ctx_input(**base_attributes) }

    it "JSON serializable な ctx_input Hash を返す(BacktestContext と同じキー構造)" do
      expect(subject).to include(
        "candle" => base_attributes[:candle],
        "balance" => "10000.0",
        "state" => { "counter" => 0 },
        "funding_rate" => "0.0001",
        "last_candles" => []
      )
      expect(subject["position"]).to include(
        "side" => "long",
        "size" => "0.01",
        "entry_price" => "50000.0"
      )
    end

    it "mark_basis / spot_basis キーは含まない(live 禁止入力のため)" do
      expect(subject).not_to have_key("mark_basis")
      expect(subject).not_to have_key("spot_basis")
    end
  end

  describe ".from_ctx_input" do
    let(:ctx_input) { described_class.build_ctx_input(**base_attributes) }
    subject { described_class.from_ctx_input(ctx_input) }

    it "Domain::LiveContext のインスタンスを再構築する" do
      result = subject
      expect(result.candle).to eq(base_attributes[:candle])
      expect(result.balance).to eq(BigDecimal("10000"))
      expect(result.state).to eq({ "counter" => 0 })
      expect(result.funding_rate).to eq(BigDecimal("0.0001"))
    end
  end

  describe "#initialize" do
    subject { described_class.new(**base_attributes) }

    it "candle / position / balance / state / funding_rate / last_candles を保持する" do
      ctx = subject
      expect(ctx.candle).to eq(base_attributes[:candle])
      expect(ctx.position).to eq(position)
      expect(ctx.balance).to eq(BigDecimal("10000"))
      expect(ctx.state).to eq({ "counter" => 0 })
      expect(ctx.funding_rate).to eq(BigDecimal("0.0001"))
      expect(ctx.last_candles).to eq([])
    end

    it "order_intents は空配列で初期化される" do
      expect(subject.order_intents).to eq([])
    end
  end

  describe "MVP 禁止入力(レビュー重要 1 反映: 2 メソッドのみ)" do
    let(:ctx) { described_class.new(**base_attributes) }

    context "ctx.mark_basis を呼ぶ場合" do
      it "Domain::LiveContext::NotSupportedInLiveError を raise する" do
        expect { ctx.mark_basis }.to raise_error(
          Domain::LiveContext::NotSupportedInLiveError,
          /mark_basis/
        )
      end
    end

    context "ctx.spot_basis を呼ぶ場合" do
      it "Domain::LiveContext::NotSupportedInLiveError を raise する" do
        expect { ctx.spot_basis }.to raise_error(
          Domain::LiveContext::NotSupportedInLiveError,
          /spot_basis/
        )
      end
    end
  end

  describe "#ai_filter スタブ(Phase 3.3 で AiFilterService 置換予定)" do
    let(:ctx) { described_class.new(**base_attributes) }

    it "常に enter: true を返す(MVP は live 環境でも一旦許可)" do
      result = ctx.ai_filter(template: :entry_filter, context: {})
      expect(result).to eq({ enter: true, reason: "live stub" })
    end
  end

  describe "#last_n_candles" do
    let(:base_attributes_with_candles) do
      base_attributes.merge(
        last_candles: 5.times.map { |i| { "ts" => i.to_s, "close" => "100" } }
      )
    end

    let(:ctx) { described_class.new(**base_attributes_with_candles) }

    it "直近 N 本の candle を返す" do
      expect(ctx.last_n_candles(3).size).to eq(3)
    end
  end

  describe "#sma" do
    let(:closes) { [ 100, 200, 300 ] }
    let(:base_attributes_with_candles) do
      base_attributes.merge(
        last_candles: closes.map { |c| { "close" => c.to_s } }
      )
    end
    let(:ctx) { described_class.new(**base_attributes_with_candles) }

    it "BacktestContext と同じロジックで単純移動平均を計算する" do
      expect(ctx.sma(3)).to eq(BigDecimal("200"))
    end

    it "データ不足時は nil を返す" do
      expect(ctx.sma(10)).to be_nil
    end

    # Phase 3.1 レビュー R-6 反映: period=0 / 負値ゼロ除算防衛
    it "period が 0 の場合 ArgumentError raise" do
      expect { ctx.sma(0) }.to raise_error(ArgumentError, /period must be >= 1/)
    end

    it "period が負値の場合 ArgumentError raise" do
      expect { ctx.sma(-1) }.to raise_error(ArgumentError, /period must be >= 1/)
    end
  end

  describe "#rsi" do
    let(:base_attributes_with_candles) do
      base_attributes.merge(
        last_candles: 15.times.map { |i| { "close" => (100 + i).to_s } }
      )
    end
    let(:ctx) { described_class.new(**base_attributes_with_candles) }

    it "BacktestContext と同じロジックで RSI を計算する(連続上昇で 100)" do
      expect(ctx.rsi(14)).to eq(BigDecimal("100"))
    end

    it "データ不足時は nil を返す" do
      ctx_short = described_class.new(**base_attributes)
      expect(ctx_short.rsi(14)).to be_nil
    end

    # Phase 3.1 レビュー R-6 反映: period=0 / 負値ゼロ除算防衛
    it "period が 0 の場合 ArgumentError raise" do
      expect { ctx.rsi(0) }.to raise_error(ArgumentError, /period must be >= 1/)
    end

    it "period が負値の場合 ArgumentError raise" do
      expect { ctx.rsi(-1) }.to raise_error(ArgumentError, /period must be >= 1/)
    end
  end

  describe "OrderProxy 経由の発注 intent 記録" do
    let(:ctx) { described_class.new(**base_attributes) }

    it "ctx.order.entry が order_intents に追加される" do
      ctx.order.entry(side: :long, size: BigDecimal("0.01"))
      expect(ctx.order_intents.size).to eq(1)
      expect(ctx.order_intents.first["side"]).to eq("long")
    end

    it "ctx.order.close が order_intents に追加される" do
      ctx.order.close
      expect(ctx.order_intents.size).to eq(1)
      expect(ctx.order_intents.first["side"]).to eq("close")
    end
  end
end
