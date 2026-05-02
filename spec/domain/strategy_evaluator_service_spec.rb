require "rails_helper"

RSpec.describe Domain::StrategyEvaluatorService do
  let(:service) { described_class.new }

  def build_trade(entry_at:, exit_at:, pnl:)
    {
      entry_at: entry_at,
      exit_at: exit_at,
      side: "long",
      entry_price: BigDecimal("100"),
      exit_price: BigDecimal("100"),
      quantity: BigDecimal("1"),
      pnl: BigDecimal(pnl.to_s)
    }
  end

  describe "#evaluate" do
    subject { service.evaluate(trades: trades, equity_curve: equity_curve) }

    context "trades が空配列の場合" do
      let(:trades) { [] }
      let(:equity_curve) { [] }

      it "全 metrics が初期値の VO を返す" do
        expect(subject).to be_a(Domain::PnLMetricsValueObject)
        expect(subject.win_rate).to eq(BigDecimal("0"))
        expect(subject.total_pnl).to eq(BigDecimal("0"))
        expect(subject.max_drawdown).to eq(BigDecimal("0"))
        expect(subject.sharpe_ratio).to eq(BigDecimal("0"))
        expect(subject.sortino_ratio).to eq(BigDecimal("0"))
        expect(subject.volatility).to eq(BigDecimal("0"))
        expect(subject.profit_factor).to eq(BigDecimal("0"))
        expect(subject.total_trades).to eq(0)
        expect(subject.avg_holding_seconds).to eq(0)
      end
    end

    context "全勝 trade の場合(win_rate=1)" do
      let(:trades) do
        [
          build_trade(entry_at: Time.utc(2026, 1, 1, 0), exit_at: Time.utc(2026, 1, 1, 1), pnl: 100),
          build_trade(entry_at: Time.utc(2026, 1, 2, 0), exit_at: Time.utc(2026, 1, 2, 1), pnl: 200)
        ]
      end
      let(:equity_curve) { [] }

      it "win_rate が 1 を返す" do
        expect(subject.win_rate).to eq(BigDecimal("1"))
        expect(subject.total_trades).to eq(2)
      end
    end

    context "全敗 trade の場合(win_rate=0)" do
      let(:trades) do
        [
          build_trade(entry_at: Time.utc(2026, 1, 1, 0), exit_at: Time.utc(2026, 1, 1, 1), pnl: -100),
          build_trade(entry_at: Time.utc(2026, 1, 2, 0), exit_at: Time.utc(2026, 1, 2, 1), pnl: -50)
        ]
      end
      let(:equity_curve) { [] }

      it "win_rate が 0 を返す" do
        expect(subject.win_rate).to eq(BigDecimal("0"))
      end
    end

    context "勝ち負け半々 trade の場合(win_rate=0.5)" do
      let(:trades) do
        [
          build_trade(entry_at: Time.utc(2026, 1, 1, 0), exit_at: Time.utc(2026, 1, 1, 1), pnl: 100),
          build_trade(entry_at: Time.utc(2026, 1, 2, 0), exit_at: Time.utc(2026, 1, 2, 1), pnl: -50)
        ]
      end
      let(:equity_curve) { [] }

      it "win_rate / total_pnl / profit_factor が正しく算出される" do
        expect(subject.win_rate).to eq(BigDecimal("0.5"))
        expect(subject.total_pnl).to eq(BigDecimal("50"))
        expect(subject.profit_factor).to eq(BigDecimal("100") / BigDecimal("50"))
      end
    end

    context "max_drawdown 計算で peak → trough の谷がある場合" do
      let(:trades) { [] }
      let(:equity_curve) do
        [
          { ts: Time.utc(2026, 1, 1), equity: BigDecimal("10000") },
          { ts: Time.utc(2026, 1, 2), equity: BigDecimal("11000") },
          { ts: Time.utc(2026, 1, 3), equity: BigDecimal("8800") },
          { ts: Time.utc(2026, 1, 4), equity: BigDecimal("12000") }
        ]
      end

      it "max_drawdown が (11000 - 8800) / 11000 を返す" do
        expected = (BigDecimal("11000") - BigDecimal("8800")) / BigDecimal("11000")
        expect(subject.max_drawdown).to eq(expected)
      end
    end

    context "全 daily_pnl が同値で volatility=0 の場合" do
      let(:trades) do
        [
          build_trade(entry_at: Time.utc(2026, 1, 1, 0), exit_at: Time.utc(2026, 1, 1, 1), pnl: 100),
          build_trade(entry_at: Time.utc(2026, 1, 2, 0), exit_at: Time.utc(2026, 1, 2, 1), pnl: 100)
        ]
      end
      let(:equity_curve) { [] }

      it "sharpe_ratio が 0 を返す(volatility=0 ハンドリング)" do
        expect(subject.volatility).to eq(BigDecimal("0"))
        expect(subject.sharpe_ratio).to eq(BigDecimal("0"))
      end
    end

    context "全 daily_pnl が正で downside_std=0 の場合" do
      let(:trades) do
        [
          build_trade(entry_at: Time.utc(2026, 1, 1, 0), exit_at: Time.utc(2026, 1, 1, 1), pnl: 100),
          build_trade(entry_at: Time.utc(2026, 1, 2, 0), exit_at: Time.utc(2026, 1, 2, 1), pnl: 200)
        ]
      end
      let(:equity_curve) { [] }

      it "sortino_ratio が 0 を返す(downside_std=0 ハンドリング)" do
        expect(subject.sortino_ratio).to eq(BigDecimal("0"))
      end
    end

    context "loss が 0(全勝)で profit_factor=0 ハンドリングの場合" do
      let(:trades) do
        [
          build_trade(entry_at: Time.utc(2026, 1, 1, 0), exit_at: Time.utc(2026, 1, 1, 1), pnl: 100)
        ]
      end
      let(:equity_curve) { [] }

      it "profit_factor が 0 を返す(losses.zero? ハンドリング)" do
        expect(subject.profit_factor).to eq(BigDecimal("0"))
      end
    end

    context "avg_holding_seconds 計算で複数 trade の保有時間が異なる場合" do
      let(:trades) do
        [
          build_trade(entry_at: Time.utc(2026, 1, 1, 0, 0, 0), exit_at: Time.utc(2026, 1, 1, 1, 0, 0), pnl: 100),
          build_trade(entry_at: Time.utc(2026, 1, 2, 0, 0, 0), exit_at: Time.utc(2026, 1, 2, 3, 0, 0), pnl: 200)
        ]
      end
      let(:equity_curve) { [] }

      it "保有秒数の平均が返される" do
        expect(subject.avg_holding_seconds).to eq((3_600 + 10_800) / 2)
      end
    end

    context "重要 4: BigMath.sqrt による精度確認" do
      let(:trades) do
        [
          build_trade(entry_at: Time.utc(2026, 1, 1, 0), exit_at: Time.utc(2026, 1, 1, 1), pnl: 1),
          build_trade(entry_at: Time.utc(2026, 1, 2, 0), exit_at: Time.utc(2026, 1, 2, 1), pnl: 3),
          build_trade(entry_at: Time.utc(2026, 1, 3, 0), exit_at: Time.utc(2026, 1, 3, 1), pnl: 5)
        ]
      end
      let(:equity_curve) { [] }

      it "volatility が BigDecimal として返却される(Float 経由しない)" do
        expect(subject.volatility).to be_a(BigDecimal)
      end

      it "sharpe_ratio が BigDecimal として返却される" do
        expect(subject.sharpe_ratio).to be_a(BigDecimal)
      end
    end
  end
end
