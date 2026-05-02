require "rails_helper"

RSpec.describe Domain::PnLMetricsValueObject do
  let(:base_attributes) do
    {
      win_rate: BigDecimal("0.55"),
      total_pnl: BigDecimal("123.45"),
      max_drawdown: BigDecimal("0.12"),
      sharpe_ratio: BigDecimal("1.5"),
      sortino_ratio: BigDecimal("2.1"),
      volatility: BigDecimal("0.08"),
      profit_factor: BigDecimal("1.8"),
      total_trades: 42,
      avg_holding_seconds: 3_600
    }
  end

  describe "#initialize" do
    subject { described_class.new(**base_attributes) }

    context "全 keyword 引数が揃っている場合" do
      it "全属性が attr_reader で公開される" do
        expect(subject.win_rate).to eq(BigDecimal("0.55"))
        expect(subject.total_pnl).to eq(BigDecimal("123.45"))
        expect(subject.max_drawdown).to eq(BigDecimal("0.12"))
        expect(subject.sharpe_ratio).to eq(BigDecimal("1.5"))
        expect(subject.sortino_ratio).to eq(BigDecimal("2.1"))
        expect(subject.volatility).to eq(BigDecimal("0.08"))
        expect(subject.profit_factor).to eq(BigDecimal("1.8"))
        expect(subject.total_trades).to eq(42)
        expect(subject.avg_holding_seconds).to eq(3_600)
      end
    end

    context "keyword 引数が不足している場合" do
      it "ArgumentError を raise する" do
        expect { described_class.new(win_rate: BigDecimal("0.5")) }.to raise_error(ArgumentError)
      end
    end
  end

  describe "#to_h" do
    subject { described_class.new(**base_attributes).to_h }

    context "全 keyword 引数で初期化された VO の場合" do
      it "全属性を Hash で返却する(モデル保存用)" do
        expect(subject).to eq(base_attributes)
      end
    end
  end

  describe "不変性(setter なし)" do
    subject { described_class.new(**base_attributes) }

    %i[win_rate total_pnl max_drawdown sharpe_ratio sortino_ratio volatility profit_factor total_trades avg_holding_seconds].each do |attr|
      context "#{attr} の setter が定義されていない場合" do
        it "respond_to? が false を返す" do
          expect(subject.respond_to?("#{attr}=")).to be false
        end
      end
    end
  end
end
