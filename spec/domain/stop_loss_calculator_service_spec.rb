require "rails_helper"

RSpec.describe Domain::StopLossCalculatorService do
  let(:service) { described_class.new }

  describe "#calculate_tp" do
    subject do
      service.calculate_tp(entry_price: entry_price, side: side, tp_pct: tp_pct)
    end

    context "long ポジションで tp_pct = 0.02 の場合" do
      let(:entry_price) { BigDecimal("50000") }
      let(:side) { :long }
      let(:tp_pct) { BigDecimal("0.02") }

      it "entry_price * (1 + tp_pct) を返す(50000 * 1.02 = 51000)" do
        expect(subject).to eq(BigDecimal("51000"))
      end
    end

    context "short ポジションで tp_pct = 0.02 の場合" do
      let(:entry_price) { BigDecimal("50000") }
      let(:side) { :short }
      let(:tp_pct) { BigDecimal("0.02") }

      it "entry_price * (1 - tp_pct) を返す(50000 * 0.98 = 49000)" do
        expect(subject).to eq(BigDecimal("49000"))
      end
    end

    context "tp_pct = 0 の場合" do
      let(:entry_price) { BigDecimal("50000") }
      let(:side) { :long }
      let(:tp_pct) { BigDecimal("0") }

      it "entry_price をそのまま返す" do
        expect(subject).to eq(BigDecimal("50000"))
      end
    end

    context "未対応の side が指定された場合" do
      let(:entry_price) { BigDecimal("50000") }
      let(:side) { :unknown }
      let(:tp_pct) { BigDecimal("0.02") }

      it "ArgumentError raise(fail-fast)" do
        expect { subject }.to raise_error(ArgumentError, /unsupported side/)
      end
    end
  end

  describe "#calculate_sl" do
    subject do
      service.calculate_sl(entry_price: entry_price, side: side, sl_pct: sl_pct)
    end

    context "long ポジションで sl_pct = 0.02 の場合" do
      let(:entry_price) { BigDecimal("50000") }
      let(:side) { :long }
      let(:sl_pct) { BigDecimal("0.02") }

      it "entry_price * (1 - sl_pct) を返す(50000 * 0.98 = 49000)" do
        expect(subject).to eq(BigDecimal("49000"))
      end
    end

    context "short ポジションで sl_pct = 0.02 の場合" do
      let(:entry_price) { BigDecimal("50000") }
      let(:side) { :short }
      let(:sl_pct) { BigDecimal("0.02") }

      it "entry_price * (1 + sl_pct) を返す(50000 * 1.02 = 51000)" do
        expect(subject).to eq(BigDecimal("51000"))
      end
    end

    context "sl_pct = 0 の場合" do
      let(:entry_price) { BigDecimal("50000") }
      let(:side) { :long }
      let(:sl_pct) { BigDecimal("0") }

      it "entry_price をそのまま返す" do
        expect(subject).to eq(BigDecimal("50000"))
      end
    end

    context "未対応の side が指定された場合" do
      let(:entry_price) { BigDecimal("50000") }
      let(:side) { :unknown }
      let(:sl_pct) { BigDecimal("0.02") }

      it "ArgumentError raise(fail-fast)" do
        expect { subject }.to raise_error(ArgumentError, /unsupported side/)
      end
    end
  end
end
