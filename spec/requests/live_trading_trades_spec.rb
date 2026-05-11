require "rails_helper"

RSpec.describe "LiveTradingTrades(View)", type: :request do
  let!(:definition) { Strategy::Definition.create!(name: "LT UI", market_type: "futures", status: "active") }
  let(:script_body) do
    <<~RUBY
      class Sample < Domain::TradingScriptBase
        def on_tick(ctx, candle); end
      end
    RUBY
  end
  let!(:revision) do
    Strategy::Revision.create!(
      strategy_definition: definition, revision_number: 1, script_content: script_body,
      script_entrypoint: "Sample", status: "promoted", ast_validation_status: "passed",
      uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false,
      approved_at: Time.current, promoted_at: Time.current
    )
  end
  let!(:risk_policy) do
    Risk::Policy.create!(
      name: "LT UI Policy", max_drawdown_pct: BigDecimal("20"), consecutive_loss_limit: 5,
      max_position_exposure_usdt: BigDecimal("1000"), max_leverage: 10, cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end
  let!(:session) do
    LiveTrading::Session.create!(
      strategy_definition: definition, strategy_revision: revision, risk_policy_id: risk_policy.id,
      symbol: "BTCUSDT", leverage: 10, margin_mode: "isolated", position_mode: "one_way_mode",
      asset_mode: "single", margin_coin: "USDT", emergency_stop_mode: "cancel_only", status: "running"
    )
  end
  let!(:trade) do
    LiveTrading::Trade.create!(
      live_trading_session: session, strategy_revision: revision,
      symbol: "BTCUSDT", side: "long", quantity: BigDecimal("0.05"),
      status: "open", entry_price: BigDecimal("50000"), entry_at: 1.hour.ago
    )
  end

  describe "GET /live_trading_trades/:id" do
    subject { get live_trading_trade_path(trade) }

    context "trade に Order / AlgoOrder / Fill が存在する場合" do
      let!(:order) do
        Exchange::Order.create!(
          live_trading_trade: trade, strategy_revision: revision,
          symbol: "BTCUSDT", side: "long", trade_side: "open",
          order_type: "limit", size: BigDecimal("0.05"), price: BigDecimal("50000"),
          status: "filled", force: "gtc", client_oid: "client-oid-1",
          bitget_order_id: "bitget-1", reduce_only: false
        )
      end
      let!(:algo_order) do
        Exchange::AlgoOrder.create!(
          live_trading_trade: trade, strategy_revision: revision,
          algo_type: "sl", bitget_algo_id: "algo-1",
          trigger_price: BigDecimal("49000"), status: "pending"
        )
      end
      let!(:fill) do
        Exchange::Fill.create!(
          exchange_order: order, bitget_fill_id: "fill-1",
          fee: BigDecimal("0.05"), fee_coin: "USDT",
          filled_at: 30.minutes.ago, price: BigDecimal("50000"), size: BigDecimal("0.05")
        )
      end

      it "200 OK + trade + Order / AlgoOrder / Fill 一覧を表示する" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(trade.id.to_s)
        expect(response.body).to include("BTCUSDT")
        expect(response.body).to include("long")
        expect(response.body).to include("client-oid-1")
        expect(response.body).to include("bitget-1")
        expect(response.body).to include("algo-1")
        expect(response.body).to include("fill-1")
      end
    end

    context "trade に Order / AlgoOrder / Fill が 0 件の場合" do
      it "200 OK + 各セクションに空メッセージ" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Order が登録されていません")
        expect(response.body).to include("AlgoOrder が登録されていません")
        expect(response.body).to include("Fill が登録されていません")
      end
    end

    context "存在しない trade_id の場合" do
      subject { get live_trading_trade_path(0) }

      it "一覧 redirect + flash alert" do
        subject
        expect(response).to redirect_to(live_trading_sessions_path)
        expect(flash[:alert]).to be_present
      end
    end
  end
end
