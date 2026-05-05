require "rails_helper"

RSpec.describe Domain::RiskGuardService do
  let(:risk_policy) do
    Risk::Policy.create!(
      name: "Test Policy",
      max_drawdown_pct: BigDecimal("20"),
      consecutive_loss_limit: 3,
      max_position_exposure_usdt: BigDecimal("1000"),
      max_leverage: 10,
      cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end
  let(:definition) do
    Strategy::Definition.create!(name: "Live Strat", market_type: "futures", status: "active")
  end
  let(:script_body) do
    "class Sample < Domain::TradingScriptBase; def on_tick(ctx, candle); end; end"
  end
  let(:revision) do
    Strategy::Revision.create!(
      strategy_definition: definition,
      revision_number: 1,
      script_content: script_body,
      script_entrypoint: "Sample",
      status: "promoted",
      ast_validation_status: "passed",
      uses_live_forbidden_input: false,
      ai_filter_enabled: false,
      ai_sizing_enabled: false,
      approved_at: Time.current,
      promoted_at: Time.current
    )
  end
  let(:session) do
    LiveTrading::Session.create!(
      strategy_definition: definition,
      strategy_revision: revision,
      risk_policy: risk_policy,
      symbol: "BTCUSDT",
      leverage: 5,
      margin_mode: "isolated",
      position_mode: "one_way_mode",
      asset_mode: "single",
      margin_coin: "USDT",
      emergency_stop_mode: "cancel_only",
      status: "running"
    )
  end

  let(:service) { described_class.new }

  describe "#allow_entry?" do
    subject do
      service.allow_entry?(
        session: session,
        balance: balance,
        candidate_size: candidate_size
      )
    end

    let(:balance) { BigDecimal("10000") }

    context "candidate_size が max_position_exposure_usdt 以下かつ leverage が max_leverage 以下の場合" do
      let(:candidate_size) { BigDecimal("500") }

      it "true を返す(エントリー許可)" do
        expect(subject).to be true
      end
    end

    context "candidate_size が max_position_exposure_usdt を超える場合" do
      let(:candidate_size) { BigDecimal("1500") }

      it "false を返す(exposure 超過)" do
        expect(subject).to be false
      end
    end

    context "session.leverage が max_leverage を超える場合" do
      before { session.update_columns(leverage: 50) }

      let(:candidate_size) { BigDecimal("500") }

      it "false を返す(leverage 超過)" do
        expect(subject).to be false
      end
    end

    context "境界値: candidate_size が max_position_exposure_usdt と等しい場合" do
      let(:candidate_size) { BigDecimal("1000") }

      it "true を返す(等しい場合は許可)" do
        expect(subject).to be true
      end
    end

    context "境界値: session.leverage が max_leverage と等しい場合" do
      before { session.update_columns(leverage: 10) }

      let(:candidate_size) { BigDecimal("500") }

      it "true を返す(等しい場合は許可)" do
        expect(subject).to be true
      end
    end
  end

  describe "#should_cooldown?" do
    subject do
      service.should_cooldown?(session: session, recent_trades: recent_trades)
    end

    let(:loss_trade) { instance_double(LiveTrading::Trade, loss?: true) }
    let(:win_trade) { instance_double(LiveTrading::Trade, loss?: false) }

    context "recent_trades が consecutive_loss_limit(3)件未満の場合" do
      let(:recent_trades) { [ loss_trade, loss_trade ] }

      it "false を返す(損失件数不足)" do
        expect(subject).to be false
      end
    end

    context "直近 consecutive_loss_limit(3)件すべて損失の場合" do
      let(:recent_trades) { [ loss_trade, loss_trade, loss_trade ] }

      it "true を返す(連続損失で cooldown 必要)" do
        expect(subject).to be true
      end
    end

    context "直近 consecutive_loss_limit(3)件のうち最新が利益の場合" do
      let(:recent_trades) { [ loss_trade, loss_trade, win_trade ] }

      it "false を返す(連続損失でない)" do
        expect(subject).to be false
      end
    end

    context "recent_trades が空の場合" do
      let(:recent_trades) { [] }

      it "false を返す" do
        expect(subject).to be false
      end
    end
  end

  describe "#should_halt?" do
    subject do
      service.should_halt?(session: session, account_metrics: account_metrics)
    end

    let(:account_metrics) do
      instance_double("AccountMetrics", drawdown_pct: drawdown_pct, daily_loss_usdt: daily_loss_usdt)
    end

    context "drawdown_pct が max_drawdown_pct 未満かつ daily_loss が daily_loss_limit_usdt 未満の場合" do
      let(:drawdown_pct) { BigDecimal("10") }
      let(:daily_loss_usdt) { BigDecimal("100") }

      it "false を返す(継続可)" do
        expect(subject).to be false
      end
    end

    context "drawdown_pct が max_drawdown_pct を超える場合" do
      let(:drawdown_pct) { BigDecimal("25") }
      let(:daily_loss_usdt) { BigDecimal("100") }

      it "true を返す(DD 超過で停止)" do
        expect(subject).to be true
      end
    end

    context "daily_loss が daily_loss_limit_usdt を超える場合" do
      let(:drawdown_pct) { BigDecimal("10") }
      let(:daily_loss_usdt) { BigDecimal("600") }

      it "true を返す(日次損失超過で停止)" do
        expect(subject).to be true
      end
    end

    context "境界値: drawdown_pct が max_drawdown_pct と等しい場合" do
      let(:drawdown_pct) { BigDecimal("20") }
      let(:daily_loss_usdt) { BigDecimal("100") }

      it "true を返す(等しい場合は停止)" do
        expect(subject).to be true
      end
    end

    context "境界値: daily_loss が daily_loss_limit_usdt と等しい場合" do
      let(:drawdown_pct) { BigDecimal("10") }
      let(:daily_loss_usdt) { BigDecimal("500") }

      it "true を返す(等しい場合は停止)" do
        expect(subject).to be true
      end
    end
  end
end
