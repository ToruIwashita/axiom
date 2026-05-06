require "rails_helper"

RSpec.describe Exchange::AlgoOrder, type: :model do
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
  let(:trade) do
    LiveTrading::Trade.create!(
      live_trading_session: session,
      strategy_revision: revision,
      symbol: "BTCUSDT",
      side: "long",
      quantity: BigDecimal("0.01"),
      status: "pending"
    )
  end
  let(:base_attributes) do
    {
      live_trading_trade: trade,
      strategy_revision: revision,
      algo_type: "tp",
      bitget_algo_id: "algo-12345",
      trigger_price: BigDecimal("51000"),
      execute_price: nil,
      callback_ratio: nil,
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

    %i[algo_type bitget_algo_id trigger_price status].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { base_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end

    context "bitget_algo_id が既存と重複する場合" do
      before { described_class.create!(base_attributes) }

      let(:attributes) { base_attributes }

      it "valid? が false を返し bitget_algo_id にエラー" do
        expect(subject).not_to be_valid
        expect(subject.errors[:bitget_algo_id]).to be_present
      end
    end

    # Phase 3.1 レビュー R-11 反映: trailing 時のみ callback_ratio 必須
    context "algo_type=trailing で callback_ratio が nil の場合" do
      let(:attributes) do
        base_attributes.merge(
          algo_type: "trailing",
          bitget_algo_id: "algo-trailing",
          callback_ratio: nil
        )
      end

      it "valid? が false を返し callback_ratio にエラー" do
        expect(subject).not_to be_valid
        expect(subject.errors[:callback_ratio]).to be_present
      end
    end

    context "algo_type=trailing で callback_ratio が指定されている場合" do
      let(:attributes) do
        base_attributes.merge(
          algo_type: "trailing",
          bitget_algo_id: "algo-trailing-2",
          callback_ratio: BigDecimal("0.01")
        )
      end

      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end

    context "algo_type=tp で callback_ratio が nil の場合(trailing 以外は不要)" do
      let(:attributes) do
        base_attributes.merge(
          algo_type: "tp",
          bitget_algo_id: "algo-tp-x",
          callback_ratio: nil
        )
      end

      it "valid? が true を返す(trailing 以外では callback_ratio 不要)" do
        expect(subject).to be_valid
      end
    end
  end

  describe "enums" do
    subject { described_class.new(base_attributes) }

    context "algo_type enum が 4 値定義されている" do
      it "tp/sl/trailing/trigger を全て受理する" do
        %w[tp sl trailing trigger].each do |t|
          subject.algo_type = t
          expect(subject.algo_type).to eq(t)
        end
      end

      it "未定義の algo_type は ArgumentError" do
        expect { subject.algo_type = "unknown" }.to raise_error(ArgumentError)
      end
    end

    context "status enum が 3 値定義されている" do
      it "pending/triggered/cancelled を全て受理する" do
        %w[pending triggered cancelled].each do |s|
          subject.status = s
          expect(subject.status).to eq(s)
        end
      end
    end
  end

  describe "状態遷移メソッド" do
    let(:algo_order) { described_class.create!(base_attributes) }

    describe "#mark_triggered!" do
      let(:execute_price) { BigDecimal("51000") }

      it "pending → triggered に遷移し execute_price が設定される" do
        algo_order.mark_triggered!(execute_price: execute_price)
        expect(algo_order).to be_state_triggered
        expect(algo_order.execute_price).to eq(execute_price)
      end
    end

    describe "#mark_cancelled!" do
      it "pending → cancelled に遷移する" do
        algo_order.mark_cancelled!
        expect(algo_order).to be_state_cancelled
      end
    end

    describe "状態遷移ガード(レビュー Step R-1: 不正パス)" do
      describe "#mark_triggered! は pending 以外から呼ぶと InvalidTransitionError" do
        %w[triggered cancelled].each do |bad_status|
          it "from #{bad_status}: raise" do
            algo_order.update_columns(status: bad_status)
            expect { algo_order.mark_triggered!(execute_price: BigDecimal("51000")) }
              .to raise_error(described_class::InvalidTransitionError)
          end
        end
      end

      describe "#mark_cancelled! は終端状態(triggered/cancelled)から呼ぶと InvalidTransitionError" do
        %w[triggered cancelled].each do |bad_status|
          it "from #{bad_status}: raise(冪等性ガード)" do
            algo_order.update_columns(status: bad_status)
            expect { algo_order.mark_cancelled! }.to raise_error(described_class::InvalidTransitionError)
          end
        end
      end
    end
  end

  describe "関連" do
    let(:algo_order) { described_class.create!(base_attributes) }

    it "live_trading_trade に belongs_to で繋がる" do
      expect(algo_order.live_trading_trade).to eq(trade)
    end

    it "strategy_revision に belongs_to で繋がる(監査用)" do
      expect(algo_order.strategy_revision).to eq(revision)
    end
  end
end
