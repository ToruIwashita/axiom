require "rails_helper"

RSpec.describe "BacktestingRuns(View)", type: :request do
  let!(:definition) { Strategy::Definition.create!(name: "BR View", market_type: "futures", status: "active") }
  let(:script_body) { "class S < Domain::TradingScriptBase\n  def on_tick(ctx, candle); end\nend" }
  let!(:approved_revision) do
    Strategy::Revision.create!(
      strategy_definition: definition, revision_number: 1, script_content: script_body,
      script_entrypoint: "S", status: "approved", ast_validation_status: "passed",
      uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false
    )
  end
  let!(:draft_revision) do
    Strategy::Revision.create!(
      strategy_definition: definition, revision_number: 2, script_content: script_body,
      script_entrypoint: "S", status: "draft", ast_validation_status: "passed",
      uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false
    )
  end
  let!(:risk_policy) do
    Risk::Policy.create!(
      name: "BR View Policy", max_drawdown_pct: BigDecimal("20"), consecutive_loss_limit: 5,
      max_position_exposure_usdt: BigDecimal("1000"), max_leverage: 10, cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end

  describe "GET /backtesting_runs(root)" do
    subject { get backtesting_runs_path }

    it "200 OK + 空メッセージ" do
      subject
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("バックテスト一覧")
    end
  end

  describe "GET /strategy_definitions/:id/backtesting_runs/new" do
    subject { get new_strategy_definition_backtesting_run_path(definition) }

    it "200 OK + フォーム表示 + 軽微 12: acceptable_for_backtest? 通過のみ select 候補" do
      subject
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("バックテスト実行")
      # approved Revision は select option として表示される
      expect(response.body).to include("##{approved_revision.revision_number}")
      # draft Revision は acceptable_for_backtest? = false なので除外される
      expect(response.body).not_to include(%(value="#{draft_revision.id}"))
    end
  end

  describe "GET /backtesting_runs/:id" do
    let!(:run) do
      Backtesting::Run.create!(
        strategy_definition: definition, strategy_revision: approved_revision, risk_policy: risk_policy,
        symbol: "BTCUSDT", granularity: "1H",
        period_from: Time.utc(2026, 1, 1), period_to: Time.utc(2026, 1, 31),
        fee_rate: BigDecimal("0.001"), slippage_rate: BigDecimal("0.0005"),
        status: "completed"
      )
    end

    subject { get backtesting_run_path(run) }

    it "200 OK + Run 詳細を表示する" do
      subject
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Backtesting::Run ##{run.id}")
      expect(response.body).to include("completed")
      expect(response.body).to include("BTCUSDT")
    end
  end

  describe "POST /strategy_definitions/:id/backtesting_runs" do
    around { |example| ActiveJob::Base.queue_adapter = :test; example.run }

    subject do
      post strategy_definition_backtesting_runs_path(definition), params: {
        backtesting_run: {
          strategy_revision_id: approved_revision.id,
          risk_policy_id: risk_policy.id,
          symbol: "BTCUSDT",
          granularity: "1H",
          period_from: "2026-01-01T00:00:00Z",
          period_to: "2026-01-31T00:00:00Z",
          fee_rate: "0.001",
          slippage_rate: "0.0005",
          include_funding_rate: "0",
          use_mark_basis: "0",
          use_spot_basis: "0"
        }
      }
    end

    it "Run 作成 + Job enqueue + show リダイレクト" do
      expect { subject }.to change { Backtesting::Run.count }.by(1)
        .and have_enqueued_job(BacktestExecutionJob)
      expect(response).to have_http_status(:redirect)
    end

    # Phase 3 末 multi-agent review #8 反映: Time.parse(nil) で TypeError → 500 回避
    context "period_from が nil の場合(`Time.parse(nil)` を防御)" do
      subject do
        post strategy_definition_backtesting_runs_path(definition), params: {
          backtesting_run: {
            strategy_revision_id: approved_revision.id,
            risk_policy_id: risk_policy.id,
            symbol: "BTCUSDT",
            granularity: "1H",
            period_from: nil,
            period_to: "2026-01-31T00:00:00Z",
            fee_rate: "0.001",
            slippage_rate: "0.0005"
          }
        }
      end

      it "Run 作成せず ArgumentError 経由で redirect + flash alert(500 化しない)" do
        expect { subject }.not_to change { Backtesting::Run.count }
        expect(response).to have_http_status(:redirect)
        expect(flash[:alert]).to be_present
      end
    end

    # Phase 3 末 multi-agent review 2 周目 高 R4 反映(対称性): period_to も同様にガード
    context "period_to が nil の場合(period_from と対称)" do
      subject do
        post strategy_definition_backtesting_runs_path(definition), params: {
          backtesting_run: {
            strategy_revision_id: approved_revision.id,
            risk_policy_id: risk_policy.id,
            symbol: "BTCUSDT",
            granularity: "1H",
            period_from: "2026-01-01T00:00:00Z",
            period_to: nil,
            fee_rate: "0.001",
            slippage_rate: "0.0005"
          }
        }
      end

      it "Run 作成せず redirect + flash alert(500 化しない)" do
        expect { subject }.not_to change { Backtesting::Run.count }
        expect(response).to have_http_status(:redirect)
        expect(flash[:alert]).to be_present
      end
    end

    # Phase 3 末 multi-agent review 2 周目 高 R3 反映:
    # `params[:backtesting_run]` 親 Hash 自体が nil の場合の NoMethodError → 500 を防ぐ.
    context "backtesting_run キー自体が欠落した場合(親 Hash nil)" do
      subject do
        post strategy_definition_backtesting_runs_path(definition), params: {}
      end

      it "Run 作成せず ParameterMissing 経由で redirect + flash alert(500 化しない)" do
        expect { subject }.not_to change { Backtesting::Run.count }
        expect(response).to have_http_status(:redirect)
        expect(flash[:alert]).to be_present
      end
    end
  end

  describe "POST /backtesting_runs/:id/cancel" do
    let!(:run) do
      Backtesting::Run.create!(
        strategy_definition: definition, strategy_revision: approved_revision, risk_policy: risk_policy,
        symbol: "BTCUSDT", granularity: "1H",
        period_from: Time.utc(2026, 1, 1), period_to: Time.utc(2026, 1, 31),
        fee_rate: BigDecimal("0.001"), slippage_rate: BigDecimal("0.0005"),
        status: "pending"
      )
    end

    subject { post cancel_backtesting_run_path(run) }

    it "cancelled に遷移し show にリダイレクト" do
      subject
      expect(response).to have_http_status(:redirect)
      expect(run.reload).to be_state_cancelled
    end
  end
end
