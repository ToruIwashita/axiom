require "rails_helper"

RSpec.describe "Api::V1::BacktestingRuns", type: :request do
  let!(:definition) { Strategy::Definition.create!(name: "BR Strat", market_type: "futures", status: "active") }
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
      script_entrypoint: "Sample", status: "approved", ast_validation_status: "passed",
      uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false
    )
  end
  let!(:risk_policy) do
    Risk::Policy.create!(
      name: "BR Policy", max_drawdown_pct: BigDecimal("20"), consecutive_loss_limit: 5,
      max_position_exposure_usdt: BigDecimal("1000"), max_leverage: 10, cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end
  let(:create_params) do
    {
      strategy_revision_id: revision.id,
      risk_policy_id: risk_policy.id,
      symbol: "BTCUSDT",
      granularity: "1H",
      period_from: "2026-01-01T00:00:00Z",
      period_to: "2026-01-31T23:59:59Z",
      fee_rate: "0.001",
      slippage_rate: "0.0005"
    }
  end

  describe "POST /api/v1/strategy_definitions/:id/backtesting_runs" do
    around { |example| ActiveJob::Base.queue_adapter = :test; example.run }

    subject do
      post "/api/v1/strategy_definitions/#{definition.id}/backtesting_runs",
           params: create_params, as: :json
    end

    context "valid params の場合" do
      it "202 Accepted + pending Run + Job enqueue" do
        expect { subject }.to change { Backtesting::Run.count }.by(1)
          .and have_enqueued_job(BacktestExecutionJob)
        expect(response).to have_http_status(:accepted)
        body = response.parsed_body
        expect(body["status"]).to eq("pending")
        expect(body["symbol"]).to eq("BTCUSDT")
        expect(body["fee_rate"]).to eq("0.001")
      end
    end

    context "整合検証失敗(別 Definition の Revision を指定)の場合" do
      let(:other_definition) { Strategy::Definition.create!(name: "Other", market_type: "futures", status: "active") }
      let!(:other_revision) do
        Strategy::Revision.create!(
          strategy_definition: other_definition, revision_number: 1, script_content: script_body,
          script_entrypoint: "Sample", status: "approved", ast_validation_status: "passed",
          uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false
        )
      end
      let(:create_params) { super().merge(strategy_revision_id: other_revision.id) }

      it "400 Bad Request を返す" do
        subject
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to match(/strategy_definition_id mismatch/)
      end
    end

    context "受入条件失敗(draft Revision)の場合" do
      let!(:revision) do
        Strategy::Revision.create!(
          strategy_definition: definition, revision_number: 1, script_content: script_body,
          script_entrypoint: "Sample", status: "draft", ast_validation_status: "passed",
          uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false
        )
      end

      it "400 Bad Request を返す" do
        subject
        expect(response).to have_http_status(:bad_request)
      end
    end

    context "軽微追加 A: 存在しない strategy_revision_id の場合" do
      let(:create_params) { super().merge(strategy_revision_id: 0) }

      it "404 Not Found を返す" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /api/v1/backtesting_runs/:id" do
    let!(:run) do
      Backtesting::Run.create!(
        strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy,
        symbol: "BTCUSDT", granularity: "1H",
        period_from: Time.utc(2026, 1, 1), period_to: Time.utc(2026, 1, 31),
        fee_rate: BigDecimal("0.001"), slippage_rate: BigDecimal("0.0005"),
        status: "completed"
      )
    end
    let!(:metrics) do
      Backtesting::Metrics.create!(
        run: run,
        win_rate: BigDecimal("0.5"), total_pnl: BigDecimal("100"), max_drawdown: BigDecimal("0.1"),
        sharpe_ratio: BigDecimal("1.0"), sortino_ratio: BigDecimal("1.5"), volatility: BigDecimal("0.2"),
        profit_factor: BigDecimal("1.5"), total_trades: 5, avg_holding_seconds: 3600
      )
    end

    context "存在する場合(metrics 含む)" do
      subject { get "/api/v1/backtesting_runs/#{run.id}", as: :json }

      it "200 OK + Run + metrics 入れ子で返す" do
        subject
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["id"]).to eq(run.id)
        expect(body["status"]).to eq("completed")
        expect(body["metrics"]).to be_present
        expect(body["metrics"]["win_rate"]).to eq("0.5")
        expect(body["metrics"]["total_trades"]).to eq(5)
      end
    end

    context "軽微追加 A: 存在しない場合" do
      subject { get "/api/v1/backtesting_runs/0", as: :json }

      it "404 Not Found を返す" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /api/v1/backtesting_runs" do
    let!(:run_pending) do
      Backtesting::Run.create!(
        strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy,
        symbol: "BTCUSDT", granularity: "1H",
        period_from: Time.utc(2026, 1, 1), period_to: Time.utc(2026, 1, 31),
        fee_rate: BigDecimal("0.001"), slippage_rate: BigDecimal("0.0005"),
        status: "pending", created_at: 2.days.ago
      )
    end
    let!(:run_completed) do
      Backtesting::Run.create!(
        strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy,
        symbol: "BTCUSDT", granularity: "1H",
        period_from: Time.utc(2026, 1, 1), period_to: Time.utc(2026, 1, 31),
        fee_rate: BigDecimal("0.001"), slippage_rate: BigDecimal("0.0005"),
        status: "completed", created_at: 1.day.ago
      )
    end

    context "filter なし" do
      subject { get "/api/v1/backtesting_runs", as: :json }

      it "200 OK + created_at desc 順で返す" do
        subject
        expect(response).to have_http_status(:ok)
        runs = response.parsed_body["runs"]
        expect(runs.first["status"]).to eq("completed")
      end
    end

    context "?status=pending フィルタ" do
      subject { get "/api/v1/backtesting_runs", params: { status: "pending" }, as: :json }

      it "pending のみ返す" do
        subject
        runs = response.parsed_body["runs"]
        expect(runs.size).to eq(1)
        expect(runs.first["status"]).to eq("pending")
      end
    end
  end

  describe "POST /api/v1/backtesting_runs/:id/cancel" do
    let!(:run) do
      Backtesting::Run.create!(
        strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy,
        symbol: "BTCUSDT", granularity: "1H",
        period_from: Time.utc(2026, 1, 1), period_to: Time.utc(2026, 1, 31),
        fee_rate: BigDecimal("0.001"), slippage_rate: BigDecimal("0.0005"),
        status: "pending"
      )
    end

    subject { post "/api/v1/backtesting_runs/#{run.id}/cancel", as: :json }

    it "200 OK + cancelled 状態に遷移する" do
      subject
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("cancelled")
      expect(run.reload).to be_state_cancelled
    end
  end
end
