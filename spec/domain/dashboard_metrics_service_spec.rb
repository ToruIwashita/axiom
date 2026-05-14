require "rails_helper"

RSpec.describe Domain::DashboardMetricsService do
  let(:definition) { Strategy::Definition.create!(name: "Dash Strat", market_type: "futures", status: "active") }
  let(:revision) do
    Strategy::Revision.create!(
      strategy_definition: definition,
      revision_number: 1,
      script_content: "class S < Domain::TradingScriptBase; def on_tick(ctx, candle); end; end",
      script_entrypoint: "S",
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
      name: "Dash Policy",
      max_drawdown_pct: BigDecimal("20"),
      consecutive_loss_limit: 5,
      max_position_exposure_usdt: BigDecimal("1000"),
      max_leverage: 10,
      cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end

  def create_session(status: "running", started_at: 1.hour.ago, stopped_at: nil)
    LiveTrading::Session.create!(
      strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy,
      symbol: "BTCUSDT", leverage: 10, margin_mode: "isolated",
      position_mode: "one_way_mode", asset_mode: "single", margin_coin: "USDT",
      emergency_stop_mode: "cancel_only", status: status,
      started_at: started_at, stopped_at: stopped_at
    )
  end

  def create_live_trade(session, realized_pnl:, status: "closed", exit_at: 30.minutes.ago)
    LiveTrading::Trade.create!(
      live_trading_session_id: session.id,
      strategy_revision_id: revision.id,
      symbol: "BTCUSDT", side: "long", quantity: BigDecimal("1"),
      status: status,
      entry_price: BigDecimal("100"), entry_at: 1.hour.ago,
      exit_price: BigDecimal("110"), exit_at: exit_at,
      realized_pnl: realized_pnl
    )
  end

  def create_backtest_run(status: "completed", finished_at: 1.day.ago, total_pnl: BigDecimal("100"))
    run = Backtesting::Run.create!(
      strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy,
      symbol: "BTCUSDT", granularity: "1m",
      period_from: 30.days.ago, period_to: 1.day.ago,
      fee_rate: BigDecimal("0.0006"), slippage_rate: BigDecimal("0.0001"),
      status: status, finished_at: finished_at
    )
    if status == "completed"
      Backtesting::Metrics.create!(
        run: run,
        win_rate: BigDecimal("0.5"), total_pnl: total_pnl,
        max_drawdown: BigDecimal("10"),
        sharpe_ratio: BigDecimal("1.0"), sortino_ratio: BigDecimal("1.5"),
        volatility: BigDecimal("0.1"), profit_factor: BigDecimal("1.2"),
        total_trades: 10, avg_holding_seconds: 300
      )
    end
    run
  end

  describe "#cumulative_pnl" do
    subject { described_class.new.cumulative_pnl }

    context "0 件の場合" do
      it "backtesting / live_trading とも 0 を返す + total フィールドを含まない(中-4 反映)" do
        expect(subject).to eq(backtesting: BigDecimal("0"), live_trading: BigDecimal("0"))
        expect(subject).not_to have_key(:total)
      end
    end

    context "backtesting 1 件 + live_trading 1 件" do
      let!(:session) { create_session }
      before do
        create_backtest_run(total_pnl: BigDecimal("123.45"))
        create_live_trade(session, realized_pnl: BigDecimal("67.89"))
      end

      it "それぞれの sum を個別に返す" do
        expect(subject[:backtesting]).to eq(BigDecimal("123.45"))
        expect(subject[:live_trading]).to eq(BigDecimal("67.89"))
        expect(subject).not_to have_key(:total)
      end
    end

    context "backtesting N 件 + live_trading N 件" do
      let!(:session) { create_session }
      before do
        create_backtest_run(total_pnl: BigDecimal("100"))
        create_backtest_run(total_pnl: BigDecimal("200"))
        create_live_trade(session, realized_pnl: BigDecimal("10"))
        create_live_trade(session, realized_pnl: BigDecimal("-5"))
      end

      it "個別 sum を返す(backtesting=300 / live_trading=5)" do
        expect(subject[:backtesting]).to eq(BigDecimal("300"))
        expect(subject[:live_trading]).to eq(BigDecimal("5"))
      end
    end

    # multi-agent review followup(spec coverage 高-1):
    # since 境界フィルタ(range: 30.days)外の Run / Trade が除外される事を保証
    context "range 外の Run / Trade は集計に含まれない" do
      let!(:session) { create_session }
      before do
        # range 外(31 日前)
        create_backtest_run(total_pnl: BigDecimal("999"), finished_at: 31.days.ago)
        create_live_trade(session, realized_pnl: BigDecimal("999"), exit_at: 31.days.ago)
        # range 内
        create_backtest_run(total_pnl: BigDecimal("100"), finished_at: 1.day.ago)
        create_live_trade(session, realized_pnl: BigDecimal("10"))
      end

      it "range 外(since 以前)を除外し range 内のみ sum する" do
        expect(subject[:backtesting]).to eq(BigDecimal("100"))
        expect(subject[:live_trading]).to eq(BigDecimal("10"))
      end
    end
  end

  describe "#uptime_seconds" do
    subject { described_class.new(range: 30.days).uptime_seconds }

    context "session 0 件の場合" do
      it "uptime_seconds_total: 0 + period_seconds: 30 日 / 8 status 別フィールドなし(中-5 反映)" do
        expect(subject).to eq(uptime_seconds_total: 0, period_seconds: 30.days.to_i)
        expect(subject.keys).to contain_exactly(:uptime_seconds_total, :period_seconds)
      end
    end

    context "running session 1 件(60 分前 started + stopped_at nil)" do
      before { create_session(started_at: 60.minutes.ago, stopped_at: nil) }

      it "uptime_seconds_total が約 3600 秒(running は now まで計上)" do
        expect(subject[:uptime_seconds_total]).to be_between(3590, 3610)
      end
    end

    context "stopped session 1 件(60 分前 started + 30 分前 stopped)" do
      before { create_session(status: "stopped", started_at: 60.minutes.ago, stopped_at: 30.minutes.ago) }

      it "uptime_seconds_total が約 1800 秒(stopped_at - started_at)" do
        expect(subject[:uptime_seconds_total]).to be_between(1790, 1810)
      end
    end

    # 新-中-3 反映: pluck 経由で AR インスタンス化なし(SQL 1 件)
    context "session 5 件で SQL 発行数が 1 件以内(pluck 経路 / 新-中-3 反映)" do
      before { 5.times { create_session(started_at: 30.minutes.ago, stopped_at: 10.minutes.ago) } }

      it "session 数によらず SQL 発行数が 1 件以内" do
        query_count = 0
        callback = lambda do |_name, _start, _finish, _id, payload|
          next if payload[:name] == "SCHEMA"
          next if %w[TRANSACTION BEGIN COMMIT ROLLBACK].include?(payload[:name])

          query_count += 1
        end
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          described_class.new.uptime_seconds
        end
        expect(query_count).to be <= 1
      end
    end
  end

  describe "#per_strategy_summary" do
    let!(:other_definition) do
      Strategy::Definition.create!(name: "Dash Strat 2", market_type: "futures", status: "active")
    end
    let!(:other_revision) do
      Strategy::Revision.create!(
        strategy_definition: other_definition, revision_number: 1,
        script_content: "class S2 < Domain::TradingScriptBase; def on_tick(ctx, candle); end; end",
        script_entrypoint: "S2", status: "promoted", ast_validation_status: "passed",
        uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false,
        approved_at: Time.current, promoted_at: Time.current
      )
    end
    let!(:session) { create_session }
    let!(:other_session) do
      LiveTrading::Session.create!(
        strategy_definition: other_definition, strategy_revision: other_revision, risk_policy: risk_policy,
        symbol: "BTCUSDT", leverage: 10, margin_mode: "isolated",
        position_mode: "one_way_mode", asset_mode: "single", margin_coin: "USDT",
        emergency_stop_mode: "cancel_only", status: "running",
        started_at: 1.hour.ago
      )
    end
    before do
      create_live_trade(session, realized_pnl: BigDecimal("50"))
      create_live_trade(session, realized_pnl: BigDecimal("-20"))
      LiveTrading::Trade.create!(
        live_trading_session_id: other_session.id, strategy_revision_id: other_revision.id,
        symbol: "BTCUSDT", side: "long", quantity: BigDecimal("1"),
        status: "closed",
        entry_price: BigDecimal("100"), entry_at: 1.hour.ago,
        exit_price: BigDecimal("110"), exit_at: 30.minutes.ago,
        realized_pnl: BigDecimal("80")
      )
      create_backtest_run(total_pnl: BigDecimal("100"))
      create_backtest_run(total_pnl: BigDecimal("200"))
    end

    subject { described_class.new.per_strategy_summary }

    it "Strategy::Revision 別の live_pnl / live_count / live_wins / backtest_runs を返す" do
      rev1_summary = subject.find { |s| s[:revision_id] == revision.id }
      rev2_summary = subject.find { |s| s[:revision_id] == other_revision.id }
      expect(rev1_summary).to include(
        revision_id: revision.id,
        live_pnl: BigDecimal("30"),
        live_count: 2,
        live_wins: 1,
        backtest_runs: 2
      )
      expect(rev2_summary).to include(
        revision_id: other_revision.id,
        live_pnl: BigDecimal("80"),
        live_count: 1,
        live_wins: 1,
        backtest_runs: 0
      )
    end

    it "revision_label を含む(strategy_definition.name + revision_number から構築)" do
      rev1_summary = subject.find { |s| s[:revision_id] == revision.id }
      expect(rev1_summary[:revision_label]).to be_a(String)
      expect(rev1_summary[:revision_label]).to include("Dash Strat")
    end

    # multi-agent review followup(spec coverage 高-2):
    # backtest_runs カウントは completed のみで running / failed は除外される事を保証
    context "backtest_runs カウントは completed のみ集計" do
      before do
        create_backtest_run(total_pnl: BigDecimal("999"), status: "running", finished_at: nil)
        create_backtest_run(total_pnl: BigDecimal("999"), status: "failed", finished_at: 1.hour.ago)
      end

      it "running / failed Run は backtest_runs から除外され completed のみ計上(rev1 = 2)" do
        rev1_summary = subject.find { |s| s[:revision_id] == revision.id }
        expect(rev1_summary[:backtest_runs]).to eq(2)
      end
    end

    # 新-中-2 反映: N+1 回避(group by 4 query 程度で完結)
    context "Revision 5 件でも N+1 SQL を起こさない(新-中-2 反映)" do
      before do
        3.times do |i|
          d = Strategy::Definition.create!(name: "Strat #{i + 3}", market_type: "futures", status: "active")
          Strategy::Revision.create!(
            strategy_definition: d, revision_number: 1,
            script_content: "class S#{i} < Domain::TradingScriptBase; def on_tick(ctx, candle); end; end",
            script_entrypoint: "S#{i}", status: "promoted", ast_validation_status: "passed",
            uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false,
            approved_at: Time.current, promoted_at: Time.current
          )
        end
      end

      it "Revision 数によらず SQL 発行数が 6 件以内(group by 4 + revisions 1 + definitions 1)" do
        query_count = 0
        callback = lambda do |_name, _start, _finish, _id, payload|
          next if payload[:name] == "SCHEMA"
          next if %w[TRANSACTION BEGIN COMMIT ROLLBACK].include?(payload[:name])

          query_count += 1
        end
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          described_class.new.per_strategy_summary
        end
        expect(query_count).to be <= 6
      end
    end
  end

  # 低-4 反映: logger DI(エラー追跡可能性)
  describe "logger DI" do
    it "constructor で logger を受け取れる" do
      logger = instance_double(Logger)
      expect { described_class.new(logger: logger) }.not_to raise_error
    end

    it "デフォルトは Rails.logger" do
      service = described_class.new
      expect(service.send(:logger)).to eq(Rails.logger)
    end
  end
end
