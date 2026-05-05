require "rails_helper"

RSpec.describe Exchange::Order, type: :model do
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
      symbol: "BTCUSDT",
      side: "long",
      trade_side: "open",
      order_type: "limit",
      price: BigDecimal("50000"),
      size: BigDecimal("0.01"),
      status: "pending",
      reduce_only: false,
      force: "gtc"
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

    %i[symbol side trade_side order_type size status force].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { base_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end

    context "size が 0 以下の場合" do
      let(:attributes) { base_attributes.merge(size: BigDecimal("0")) }

      it "valid? が false を返す" do
        expect(subject).not_to be_valid
        expect(subject.errors[:size]).to be_present
      end
    end
  end

  describe "enums" do
    subject { described_class.new(base_attributes) }

    context "status enum が 6 値定義されている" do
      it "pending/placed/partially_filled/filled/cancelled/rejected を全て受理する" do
        %w[pending placed partially_filled filled cancelled rejected].each do |s|
          subject.status = s
          expect(subject.status).to eq(s)
        end
      end

      it "未定義の status は ArgumentError" do
        expect { subject.status = "unknown" }.to raise_error(ArgumentError)
      end
    end

    context "side enum が 2 値定義されている" do
      it "long/short を受理する" do
        subject.side = "short"
        expect(subject.side).to eq("short")
      end
    end

    context "trade_side enum が 2 値定義されている(hedge_mode 時のみ有効)" do
      it "open/close を受理する" do
        subject.trade_side = "close"
        expect(subject.trade_side).to eq("close")
      end
    end

    context "order_type enum が 2 値定義されている" do
      it "limit/market を受理する" do
        subject.order_type = "market"
        expect(subject.order_type).to eq("market")
      end
    end

    context "force enum が 4 値定義されている" do
      it "gtc/ioc/fok/post_only を全て受理する" do
        %w[gtc ioc fok post_only].each do |f|
          subject.force = f
          expect(subject.force).to eq(f)
        end
      end
    end
  end

  describe "client_oid 冪等性キーの自動生成" do
    context "client_oid を明示しない場合" do
      let(:order) { described_class.new(base_attributes) }

      it "before_validation で SecureRandom.uuid が自動セットされる" do
        order.valid?
        expect(order.client_oid).to be_present
        expect(order.client_oid).to match(/\A[0-9a-f-]{36}\z/)
      end
    end

    context "client_oid を明示した場合" do
      let(:explicit_oid) { "explicit-client-oid" }
      let(:order) { described_class.new(base_attributes.merge(client_oid: explicit_oid)) }

      it "明示値が保持される" do
        order.valid?
        expect(order.client_oid).to eq(explicit_oid)
      end
    end

    context "client_oid が既存と重複する場合" do
      let(:duplicated_oid) { "duplicated-oid" }
      before do
        described_class.create!(base_attributes.merge(client_oid: duplicated_oid))
      end

      let(:order) { described_class.new(base_attributes.merge(client_oid: duplicated_oid)) }

      it "valid? が false を返す" do
        expect(order).not_to be_valid
        expect(order.errors[:client_oid]).to be_present
      end
    end
  end

  describe "状態遷移メソッド" do
    let(:order) { described_class.create!(base_attributes) }

    describe "#mark_placed!" do
      let(:bitget_order_id) { "bitget-12345" }
      let(:placed_at) { Time.utc(2026, 5, 5, 12, 0, 0) }

      it "pending → placed に遷移し bitget_order_id / placed_at が設定される" do
        order.mark_placed!(bitget_order_id: bitget_order_id, placed_at: placed_at)
        expect(order).to be_state_placed
        expect(order.bitget_order_id).to eq(bitget_order_id)
        expect(order.placed_at).to eq(placed_at)
      end
    end

    describe "#mark_partially_filled!" do
      it "placed → partially_filled に遷移する" do
        order.update!(status: "placed")
        order.mark_partially_filled!
        expect(order).to be_state_partially_filled
      end
    end

    describe "#mark_filled!" do
      let(:finished_at) { Time.utc(2026, 5, 5, 13, 0, 0) }

      it "placed → filled に遷移し finished_at が設定される" do
        order.update!(status: "placed")
        order.mark_filled!(finished_at: finished_at)
        expect(order).to be_state_filled
        expect(order.finished_at).to eq(finished_at)
      end
    end

    describe "#mark_cancelled!" do
      let(:finished_at) { Time.utc(2026, 5, 5, 13, 30, 0) }

      it "placed → cancelled に遷移し finished_at が設定される" do
        order.update!(status: "placed")
        order.mark_cancelled!(finished_at: finished_at)
        expect(order).to be_state_cancelled
        expect(order.finished_at).to eq(finished_at)
      end
    end

    describe "#mark_rejected!" do
      let(:finished_at) { Time.utc(2026, 5, 5, 12, 0, 30) }

      it "pending → rejected に遷移し finished_at が設定される" do
        order.mark_rejected!(finished_at: finished_at)
        expect(order).to be_state_rejected
        expect(order.finished_at).to eq(finished_at)
      end
    end
  end

  describe "関連" do
    let(:order) { described_class.create!(base_attributes) }

    it "live_trading_trade に belongs_to で繋がる" do
      expect(order.live_trading_trade).to eq(trade)
    end

    it "strategy_revision に belongs_to で繋がる(監査用)" do
      expect(order.strategy_revision).to eq(revision)
    end
  end
end
