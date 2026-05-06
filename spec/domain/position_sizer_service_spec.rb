require "rails_helper"

RSpec.describe Domain::PositionSizerService do
  let(:service) { described_class.new }

  describe "#calculate_atr_based" do
    subject do
      service.calculate_atr_based(
        balance: balance,
        atr: atr,
        risk_pct: risk_pct,
        leverage: leverage
      )
    end

    context "標準的な ATR ベース計算" do
      let(:balance) { BigDecimal("10000") }
      let(:atr) { BigDecimal("100") }
      let(:risk_pct) { BigDecimal("0.01") }
      let(:leverage) { 10 }

      it "balance * risk_pct * leverage / atr を返す" do
        # 10000 * 0.01 * 10 / 100 = 10
        expect(subject).to eq(BigDecimal("10"))
      end
    end

    context "atr が 0 の場合" do
      let(:balance) { BigDecimal("10000") }
      let(:atr) { BigDecimal("0") }
      let(:risk_pct) { BigDecimal("0.01") }
      let(:leverage) { 10 }

      it "ZeroDivisionError ではなく nil を返す(防衛的フォールバック)" do
        expect(subject).to be_nil
      end
    end

    # Phase 3.1 レビュー R-7 反映: 負値防衛
    context "atr が負値の場合" do
      let(:balance) { BigDecimal("10000") }
      let(:atr) { BigDecimal("-1") }
      let(:risk_pct) { BigDecimal("0.01") }
      let(:leverage) { 10 }

      it "nil を返す(ATR は理論上常に非負,負値は不正データ)" do
        expect(subject).to be_nil
      end
    end

    context "balance が負値の場合" do
      let(:balance) { BigDecimal("-1") }
      let(:atr) { BigDecimal("100") }
      let(:risk_pct) { BigDecimal("0.01") }
      let(:leverage) { 10 }

      it "ArgumentError raise(残高は非負前提)" do
        expect { subject }.to raise_error(ArgumentError, /balance must be >= 0/)
      end
    end

    context "risk_pct が負値の場合" do
      let(:balance) { BigDecimal("10000") }
      let(:atr) { BigDecimal("100") }
      let(:risk_pct) { BigDecimal("-0.01") }
      let(:leverage) { 10 }

      it "ArgumentError raise" do
        expect { subject }.to raise_error(ArgumentError, /risk_pct must be >= 0/)
      end
    end

    context "leverage が 0 以下の場合" do
      let(:balance) { BigDecimal("10000") }
      let(:atr) { BigDecimal("100") }
      let(:risk_pct) { BigDecimal("0.01") }
      let(:leverage) { 0 }

      it "ArgumentError raise(レバレッジは 1 以上)" do
        expect { subject }.to raise_error(ArgumentError, /leverage must be >= 1/)
      end
    end

    context "balance が 0 の場合" do
      let(:balance) { BigDecimal("0") }
      let(:atr) { BigDecimal("100") }
      let(:risk_pct) { BigDecimal("0.01") }
      let(:leverage) { 10 }

      it "0 を返す(サイジング不可)" do
        expect(subject).to eq(BigDecimal("0"))
      end
    end

    context "leverage が 1 の場合(現物相当)" do
      let(:balance) { BigDecimal("10000") }
      let(:atr) { BigDecimal("100") }
      let(:risk_pct) { BigDecimal("0.02") }
      let(:leverage) { 1 }

      it "balance * risk_pct / atr を返す" do
        # 10000 * 0.02 * 1 / 100 = 2
        expect(subject).to eq(BigDecimal("2"))
      end
    end
  end

  describe "#calculate_fixed" do
    subject { service.calculate_fixed(size: size) }

    context "正の固定サイズが指定された場合" do
      let(:size) { BigDecimal("0.5") }

      it "そのまま返す" do
        expect(subject).to eq(BigDecimal("0.5"))
      end
    end

    context "0 が指定された場合" do
      let(:size) { BigDecimal("0") }

      it "0 を返す" do
        expect(subject).to eq(BigDecimal("0"))
      end
    end

    # Phase 3.1 レビュー R-7 反映
    context "負値が指定された場合" do
      let(:size) { BigDecimal("-1") }

      it "ArgumentError raise" do
        expect { subject }.to raise_error(ArgumentError, /size must be >= 0/)
      end
    end
  end

  describe "#calculate_proportional" do
    subject do
      service.calculate_proportional(balance: balance, ratio: ratio, leverage: leverage)
    end

    context "balance * ratio * leverage を計算する" do
      let(:balance) { BigDecimal("10000") }
      let(:ratio) { BigDecimal("0.05") }
      let(:leverage) { 5 }

      it "balance * ratio * leverage を返す" do
        # 10000 * 0.05 * 5 = 2500
        expect(subject).to eq(BigDecimal("2500"))
      end
    end

    context "ratio が 0 の場合" do
      let(:balance) { BigDecimal("10000") }
      let(:ratio) { BigDecimal("0") }
      let(:leverage) { 5 }

      it "0 を返す" do
        expect(subject).to eq(BigDecimal("0"))
      end
    end

    context "leverage が 1 の場合(現物相当)" do
      let(:balance) { BigDecimal("10000") }
      let(:ratio) { BigDecimal("0.1") }
      let(:leverage) { 1 }

      it "balance * ratio を返す" do
        expect(subject).to eq(BigDecimal("1000"))
      end
    end

    # Phase 3.1 レビュー R-7 反映: 負値防衛
    context "balance が負値の場合" do
      let(:balance) { BigDecimal("-1") }
      let(:ratio) { BigDecimal("0.1") }
      let(:leverage) { 5 }

      it "ArgumentError raise" do
        expect { subject }.to raise_error(ArgumentError, /balance must be >= 0/)
      end
    end

    context "ratio が負値の場合" do
      let(:balance) { BigDecimal("10000") }
      let(:ratio) { BigDecimal("-0.1") }
      let(:leverage) { 5 }

      it "ArgumentError raise" do
        expect { subject }.to raise_error(ArgumentError, /ratio must be >= 0/)
      end
    end

    context "leverage が 0 以下の場合" do
      let(:balance) { BigDecimal("10000") }
      let(:ratio) { BigDecimal("0.1") }
      let(:leverage) { 0 }

      it "ArgumentError raise" do
        expect { subject }.to raise_error(ArgumentError, /leverage must be >= 1/)
      end
    end
  end
end
