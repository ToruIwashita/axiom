require "rails_helper"

RSpec.describe "Api::V1::BacktestingRunEquityCurve", type: :request do
  let!(:definition) { Strategy::Definition.create!(name: "EQ", market_type: "futures", status: "active") }
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
      name: "EQ", max_drawdown_pct: BigDecimal("20"), consecutive_loss_limit: 5,
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

  before do
    50.times do |i|
      Backtesting::EquityCurvePoint.create!(
        run: run,
        ts: Time.utc(2026, 1, 1) + (i * 3_600),
        equity: BigDecimal(10000 + i * 10),
        drawdown: BigDecimal("0.0"),
        position_size: BigDecimal("0")
      )
    end
  end

  describe "GET /api/v1/backtesting_runs/:id/equity_curve" do
    context "sample_size を渡さない場合(default 1000、データ数 50 < 1000)" do
      subject { get "/api/v1/backtesting_runs/#{run.id}/equity_curve", as: :json }

      it "200 OK + 全 50 件 + 各点に ts/equity/drawdown/position_size" do
        subject
        expect(response).to have_http_status(:ok)
        points = response.parsed_body["points"]
        expect(points.size).to eq(50)
        expect(points.first.keys).to contain_exactly("ts", "equity", "drawdown", "position_size")
        expect(points.first["ts"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
        expect(points.first["equity"]).to be_a(String)
      end
    end

    context "sample_size=10 を渡した場合(50 件 → 10 件以下に間引き)" do
      subject { get "/api/v1/backtesting_runs/#{run.id}/equity_curve", params: { sample_size: 10 }, as: :json }

      it "間引かれた配列を返す(size <= sample_size)" do
        subject
        points = response.parsed_body["points"]
        expect(points.size).to be <= 10
        expect(points.size).to be > 0
      end
    end

    context "sample_size 上限超過(MAX_SAMPLE_SIZE=10_000)を渡した場合" do
      subject { get "/api/v1/backtesting_runs/#{run.id}/equity_curve", params: { sample_size: 100_000 }, as: :json }

      it "clamp されて全 50 件返却(50 < 10_000 のため間引きなし)" do
        subject
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["points"].size).to eq(50)
      end
    end

    context "存在しない run_id の場合" do
      subject { get "/api/v1/backtesting_runs/0/equity_curve", as: :json }

      it "404 Not Found を返す" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
