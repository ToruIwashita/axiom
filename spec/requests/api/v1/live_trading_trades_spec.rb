require "rails_helper"

RSpec.describe "Api::V1::LiveTradingTrades", type: :request do
  let!(:definition) { Strategy::Definition.create!(name: "LT Strat", market_type: "futures", status: "active") }
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
      name: "LT Policy", max_drawdown_pct: BigDecimal("20"), consecutive_loss_limit: 5,
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

  describe "GET /api/v1/live_trading_trades/:id" do
    subject { get "/api/v1/live_trading_trades/#{trade.id}", as: :json }

    context "trade に Order / AlgoOrder / Fill が紐付く場合" do
      let!(:order1) do
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
          exchange_order: order1, bitget_fill_id: "fill-1",
          fee: BigDecimal("0.05"), fee_coin: "USDT",
          filled_at: 30.minutes.ago, price: BigDecimal("50000"), size: BigDecimal("0.05")
        )
      end

      it "200 OK + trade + orders + algo_orders + fills を nested で返却" do
        subject
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["trade"]).to include("id" => trade.id, "symbol" => "BTCUSDT", "side" => "long")
        expect(body["orders"].map { |o| o["id"] }).to contain_exactly(order1.id)
        expect(body["algo_orders"].map { |a| a["id"] }).to contain_exactly(algo_order.id)
        expect(body["fills"].map { |f| f["id"] }).to contain_exactly(fill.id)
      end

      it "order payload に side / trade_side / status / client_oid 等を含む" do
        subject
        order_payload = response.parsed_body["orders"].first
        expect(order_payload).to include(
          "id" => order1.id,
          "live_trading_trade_id" => trade.id,
          "symbol" => "BTCUSDT",
          "side" => "long",
          "trade_side" => "open",
          "order_type" => "limit",
          "status" => "filled",
          "client_oid" => "client-oid-1",
          "bitget_order_id" => "bitget-1",
          "size" => "0.05"
        )
      end

      it "fill payload は price / size / fee / filled_at を含む" do
        subject
        fill_payload = response.parsed_body["fills"].first
        expect(fill_payload).to include(
          "id" => fill.id,
          "exchange_order_id" => order1.id,
          "bitget_fill_id" => "fill-1",
          "price" => "50000.0",
          "size" => "0.05",
          "fee" => "0.05"
        )
      end
    end

    context "trade に Order / AlgoOrder / Fill が 0 件の場合" do
      it "200 OK + 各配列が空" do
        subject
        body = response.parsed_body
        expect(body["trade"]["id"]).to eq(trade.id)
        expect(body["orders"]).to eq([])
        expect(body["algo_orders"]).to eq([])
        expect(body["fills"]).to eq([])
      end
    end

    context "存在しない trade_id の場合" do
      subject { get "/api/v1/live_trading_trades/0", as: :json }

      it "404 Not Found を返す" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
