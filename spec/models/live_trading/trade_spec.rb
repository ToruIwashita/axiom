require "rails_helper"

RSpec.describe LiveTrading::Trade, type: :model do
  let(:definition) do
    Strategy::Definition.create!(name: "Live Strat", market_type: "futures", status: "active")
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
      status: "promoted",
      ast_validation_status: "passed",
      uses_live_forbidden_input: false,
      ai_filter_enabled: false,
      ai_sizing_enabled: false,
      approved_at: Time.current,
      promoted_at: Time.current
    )
  end
  let(:risk_policy) do
    Risk::Policy.create!(
      name: "Default Policy",
      max_drawdown_pct: BigDecimal("20"),
      consecutive_loss_limit: 5,
      max_position_exposure_usdt: BigDecimal("1000"),
      max_leverage: 10,
      cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end
  let(:session) do
    LiveTrading::Session.create!(
      strategy_definition: definition,
      strategy_revision: revision,
      risk_policy: risk_policy,
      symbol: "BTCUSDT",
      leverage: 10,
      margin_mode: "isolated",
      position_mode: "one_way_mode",
      asset_mode: "single",
      margin_coin: "USDT",
      emergency_stop_mode: "cancel_only",
      status: "running"
    )
  end
  let(:base_attributes) do
    {
      live_trading_session: session,
      strategy_revision: revision,
      symbol: "BTCUSDT",
      side: "long",
      quantity: BigDecimal("0.01"),
      status: "pending"
    }
  end

  describe "validations" do
    subject { described_class.new(attributes) }

    context "必須属性が全て揃っている場合" do
      let(:attributes) { base_attributes }

      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end

    %i[symbol side quantity status].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { base_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end

    context "quantity が 0 以下の場合" do
      let(:attributes) { base_attributes.merge(quantity: BigDecimal("0")) }

      it "valid? が false を返す" do
        expect(subject).not_to be_valid
        expect(subject.errors[:quantity]).to be_present
      end
    end
  end

  describe "enums" do
    subject { described_class.new(base_attributes) }

    context "status enum が 7 値定義されている" do
      it "pending/entering/open/closing/closed/cancelled/failed を全て受理する" do
        %w[pending entering open closing closed cancelled failed].each do |s|
          subject.status = s
          expect(subject.status).to eq(s)
        end
      end

      it "未定義の status は ArgumentError" do
        expect { subject.status = "unknown" }.to raise_error(ArgumentError)
      end
    end

    context "side enum が 2 値定義されている" do
      it "long/short を受理し他は ArgumentError" do
        subject.side = "short"
        expect(subject.side).to eq("short")
        expect { subject.side = "invalid" }.to raise_error(ArgumentError)
      end
    end
  end

  describe "状態遷移メソッド" do
    let(:trade) { described_class.create!(base_attributes) }

    describe "#start_entering!" do
      it "pending → entering に遷移する" do
        trade.start_entering!
        expect(trade).to be_state_entering
      end
    end

    describe "#mark_open!" do
      let(:entry_price) { BigDecimal("50000") }
      let(:entry_at) { Time.utc(2026, 5, 5, 12, 0, 0) }

      it "entering → open に遷移し entry_price / entry_at が設定される" do
        trade.update!(status: "entering")
        trade.mark_open!(entry_price: entry_price, entry_at: entry_at)
        expect(trade).to be_state_open
        expect(trade.entry_price).to eq(entry_price)
        expect(trade.entry_at).to eq(entry_at)
      end
    end

    describe "#start_closing!" do
      it "open → closing に遷移する" do
        trade.update!(status: "open", entry_price: BigDecimal("50000"), entry_at: Time.current)
        trade.start_closing!
        expect(trade).to be_state_closing
      end
    end

    describe "#mark_closed!" do
      let(:exit_price) { BigDecimal("51000") }
      let(:exit_at) { Time.utc(2026, 5, 5, 13, 0, 0) }
      let(:realized_pnl) { BigDecimal("10") }

      it "closing → closed に遷移し exit_price / exit_at / realized_pnl が設定される" do
        trade.update!(status: "closing", entry_price: BigDecimal("50000"), entry_at: Time.current)
        trade.mark_closed!(exit_price: exit_price, exit_at: exit_at, realized_pnl: realized_pnl)
        expect(trade).to be_state_closed
        expect(trade.exit_price).to eq(exit_price)
        expect(trade.exit_at).to eq(exit_at)
        expect(trade.realized_pnl).to eq(realized_pnl)
      end
    end

    describe "#mark_cancelled!" do
      it "pending → cancelled に遷移し failure_reason が設定される" do
        trade.mark_cancelled!(reason: "user cancelled")
        expect(trade).to be_state_cancelled
        expect(trade.failure_reason).to eq("user cancelled")
      end
    end

    describe "#mark_failed!" do
      it "entering → failed に遷移し failure_reason が設定される" do
        trade.update!(status: "entering")
        trade.mark_failed!(reason: "exchange rejected")
        expect(trade).to be_state_failed
        expect(trade.failure_reason).to eq("exchange rejected")
      end

      it "failure_reason は 10_000 文字を超えると truncate される" do
        long_reason = "x" * 11_000
        trade.mark_failed!(reason: long_reason)
        expect(trade.failure_reason.length).to eq(10_000)
      end
    end
  end

  describe "関連" do
    let(:trade) { described_class.create!(base_attributes) }

    it "live_trading_session に belongs_to で繋がる" do
      expect(trade.live_trading_session).to eq(session)
    end

    it "strategy_revision に belongs_to で繋がる(監査用)" do
      expect(trade.strategy_revision).to eq(revision)
    end
  end
end
