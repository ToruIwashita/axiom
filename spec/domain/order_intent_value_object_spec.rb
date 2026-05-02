require "rails_helper"

RSpec.describe Domain::OrderIntentValueObject do
  describe "#initialize" do
    context "side: :long / order_type: :market(デフォルト)で初期化した場合" do
      subject { described_class.new(side: :long, size: BigDecimal("1.0")) }

      it "全属性が正しくセットされる" do
        expect(subject.side).to eq(:long)
        expect(subject.size).to eq(BigDecimal("1.0"))
        expect(subject.order_type).to eq(:market)
        expect(subject.limit_price).to be_nil
        expect(subject.tp_pct).to be_nil
        expect(subject.sl_pct).to be_nil
      end
    end

    context "order_type: :limit + limit_price 指定で初期化した場合" do
      subject do
        described_class.new(
          side: :short,
          size: BigDecimal("0.5"),
          order_type: :limit,
          limit_price: BigDecimal("40000"),
          tp_pct: BigDecimal("0.02"),
          sl_pct: BigDecimal("0.01")
        )
      end

      it "全属性が正しくセットされる" do
        expect(subject.side).to eq(:short)
        expect(subject.order_type).to eq(:limit)
        expect(subject.limit_price).to eq(BigDecimal("40000"))
        expect(subject.tp_pct).to eq(BigDecimal("0.02"))
        expect(subject.sl_pct).to eq(BigDecimal("0.01"))
      end
    end

    context "side が許容外の値の場合" do
      subject { described_class.new(side: :neutral, size: BigDecimal("1.0")) }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /invalid side/)
      end
    end

    context "order_type が許容外の値の場合" do
      subject { described_class.new(side: :long, size: BigDecimal("1.0"), order_type: :stop) }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /invalid order_type/)
      end
    end

    context "order_type: :limit で limit_price が nil の場合" do
      subject { described_class.new(side: :long, size: BigDecimal("1.0"), order_type: :limit) }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /limit_price required/)
      end
    end
  end

  describe "#market?" do
    subject { intent.market? }

    context "order_type: :market の場合" do
      let(:intent) { described_class.new(side: :long, size: BigDecimal("1.0")) }

      it "true を返す" do
        expect(subject).to be true
      end
    end

    context "order_type: :limit の場合" do
      let(:intent) do
        described_class.new(side: :long, size: BigDecimal("1.0"), order_type: :limit, limit_price: BigDecimal("100"))
      end

      it "false を返す" do
        expect(subject).to be false
      end
    end
  end

  describe "#limit?" do
    subject { intent.limit? }

    context "order_type: :limit の場合" do
      let(:intent) do
        described_class.new(side: :long, size: BigDecimal("1.0"), order_type: :limit, limit_price: BigDecimal("100"))
      end

      it "true を返す" do
        expect(subject).to be true
      end
    end

    context "order_type: :market の場合" do
      let(:intent) { described_class.new(side: :long, size: BigDecimal("1.0")) }

      it "false を返す" do
        expect(subject).to be false
      end
    end
  end

  describe ".from_h" do
    context "成行注文 Hash から VO を構築する場合" do
      subject do
        described_class.from_h(
          "side" => "long",
          "size" => "1.5",
          "order_type" => "market"
        )
      end

      it "Symbol 化された side / order_type と BigDecimal 化された size を持つ VO を返す" do
        expect(subject.side).to eq(:long)
        expect(subject.size).to eq(BigDecimal("1.5"))
        expect(subject.order_type).to eq(:market)
        expect(subject).to be_market
      end
    end

    context "指値注文 Hash + tp_pct / sl_pct から VO を構築する場合" do
      subject do
        described_class.from_h(
          "side" => "short",
          "size" => "0.5",
          "order_type" => "limit",
          "limit_price" => "40000",
          "tp_pct" => "0.02",
          "sl_pct" => "0.01"
        )
      end

      it "全属性が BigDecimal 化された VO を返す" do
        expect(subject.side).to eq(:short)
        expect(subject.order_type).to eq(:limit)
        expect(subject.limit_price).to eq(BigDecimal("40000"))
        expect(subject.tp_pct).to eq(BigDecimal("0.02"))
        expect(subject.sl_pct).to eq(BigDecimal("0.01"))
      end
    end

    context "order_type が省略された場合" do
      subject { described_class.from_h("side" => "long", "size" => "1.0") }

      it "デフォルト :market が適用される" do
        expect(subject.order_type).to eq(:market)
      end
    end
  end
end
