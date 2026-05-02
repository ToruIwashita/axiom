require "rails_helper"

RSpec.describe "Api::V1::BacktestingRunTrades", type: :request do
  let!(:definition) { Strategy::Definition.create!(name: "T", market_type: "futures", status: "active") }
  let(:script_body) { "class S < Domain::TradingScriptBase\n  def on_tick(ctx, candle); end\nend" }
  let!(:revision) do
    Strategy::Revision.create!(
      strategy_definition: definition, revision_number: 1, script_content: script_body,
      script_entrypoint: "S", status: "approved", ast_validation_status: "passed",
      uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false
    )
  end
  let!(:risk_policy) do
    Risk::Policy.create!(
      name: "T", max_drawdown_pct: BigDecimal("20"), consecutive_loss_limit: 5,
      max_position_exposure_usdt: BigDecimal("1000"), max_leverage: 10, cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end
  let!(:run) do
    Backtesting::Run.create!(
      strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy,
      symbol: "BTCUSDT", granularity: "1H",
      period_from: Time.utc(2026, 1, 1), period_to: Time.utc(2026, 1, 31),
      fee_rate: BigDecimal("0.001"), slippage_rate: BigDecimal("0.0005"),
      status: "completed"
    )
  end
  let!(:trade) do
    Backtesting::Trade.create!(
      run: run, side: "long",
      entry_at: Time.utc(2026, 1, 5), exit_at: Time.utc(2026, 1, 5, 1),
      entry_price: BigDecimal("40000"), exit_price: BigDecimal("41000"),
      quantity: BigDecimal("0.5"), pnl: BigDecimal("500")
    )
  end

  describe "GET /api/v1/backtesting_runs/:id/trades" do
    subject { get "/api/v1/backtesting_runs/#{run.id}/trades", as: :json }

    it "200 OK + trades 配列を返す" do
      subject
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["trades"]).to be_an(Array)
      expect(body["trades"].first["side"]).to eq("long")
      expect(body["trades"].first["pnl"]).to eq("500.0")
      expect(body["trades"].first["entry_at"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end

    context "存在しない run_id の場合" do
      subject { get "/api/v1/backtesting_runs/0/trades", as: :json }

      it "404 Not Found を返す" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
