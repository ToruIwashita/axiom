require "rails_helper"

RSpec.describe Domain::PositionValueObject do
  describe "#initialize + デフォルト値" do
    subject { described_class.new }

    context "引数なしで初期化した場合" do
      it "side が nil / size が 0 / entry_price が 0 のフラットポジション" do
        expect(subject.side).to be_nil
        expect(subject.size).to eq(BigDecimal("0"))
        expect(subject.entry_price).to eq(BigDecimal("0"))
      end
    end
  end

  describe "#flat?" do
    subject { position.flat? }

    context "side が nil の場合" do
      let(:position) { described_class.new }

      it "true を返す" do
        expect(subject).to be true
      end
    end

    context "side が指定されているが size が 0 の場合" do
      let(:position) { described_class.new(side: :long, size: BigDecimal("0"), entry_price: BigDecimal("100")) }

      it "true を返す" do
        expect(subject).to be true
      end
    end

    context "ロングポジションを保有している場合" do
      let(:position) { described_class.new(side: :long, size: BigDecimal("1"), entry_price: BigDecimal("100")) }

      it "false を返す" do
        expect(subject).to be false
      end
    end
  end

  describe "#long?" do
    subject { position.long? }

    context "side: :long で size が正の場合" do
      let(:position) { described_class.new(side: :long, size: BigDecimal("1"), entry_price: BigDecimal("100")) }

      it "true を返す" do
        expect(subject).to be true
      end
    end

    context "side: :short の場合" do
      let(:position) { described_class.new(side: :short, size: BigDecimal("1"), entry_price: BigDecimal("100")) }

      it "false を返す" do
        expect(subject).to be false
      end
    end

    context "side: :long だが size が 0 の場合" do
      let(:position) { described_class.new(side: :long, size: BigDecimal("0"), entry_price: BigDecimal("100")) }

      it "false を返す" do
        expect(subject).to be false
      end
    end
  end

  describe "#short?" do
    subject { position.short? }

    context "side: :short で size が正の場合" do
      let(:position) { described_class.new(side: :short, size: BigDecimal("1"), entry_price: BigDecimal("100")) }

      it "true を返す" do
        expect(subject).to be true
      end
    end

    context "side: :long の場合" do
      let(:position) { described_class.new(side: :long, size: BigDecimal("1"), entry_price: BigDecimal("100")) }

      it "false を返す" do
        expect(subject).to be false
      end
    end
  end

  describe "#unrealized_pnl" do
    subject { position.unrealized_pnl(current_price) }

    context "フラットポジションの場合" do
      let(:position) { described_class.new }
      let(:current_price) { BigDecimal("100") }

      it "0 を返す" do
        expect(subject).to eq(BigDecimal("0"))
      end
    end

    context "ロングポジションで現在価格が建値より高い場合" do
      let(:position) { described_class.new(side: :long, size: BigDecimal("2"), entry_price: BigDecimal("100")) }
      let(:current_price) { BigDecimal("110") }

      it "size * (current - entry) を返す" do
        expect(subject).to eq(BigDecimal("20"))
      end
    end

    context "ロングポジションで現在価格が建値より安い場合" do
      let(:position) { described_class.new(side: :long, size: BigDecimal("2"), entry_price: BigDecimal("100")) }
      let(:current_price) { BigDecimal("90") }

      it "負の含み損益を返す" do
        expect(subject).to eq(BigDecimal("-20"))
      end
    end

    context "ショートポジションで現在価格が建値より高い場合" do
      let(:position) { described_class.new(side: :short, size: BigDecimal("2"), entry_price: BigDecimal("100")) }
      let(:current_price) { BigDecimal("110") }

      it "負の含み損益を返す" do
        expect(subject).to eq(BigDecimal("-20"))
      end
    end

    context "ショートポジションで現在価格が建値より安い場合" do
      let(:position) { described_class.new(side: :short, size: BigDecimal("2"), entry_price: BigDecimal("100")) }
      let(:current_price) { BigDecimal("90") }

      it "size * (entry - current) を返す" do
        expect(subject).to eq(BigDecimal("20"))
      end
    end
  end
end
