require "rails_helper"

RSpec.describe LiveTradingWorker do
  let(:process_manager) { instance_double(Domain::LiveTradingProcessManager) }
  let(:lease) { instance_double(LiveTrading::SessionLease) }
  let(:worker) { described_class.new(process_manager: process_manager) }

  let(:definition) do
    Strategy::Definition.create!(name: "Worker Strat", market_type: "futures", status: "active")
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
      name: "Worker Default Policy",
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
      status: "starting"
    )
  end

  before do
    allow(process_manager).to receive(:acquire_lease!).and_return(lease)
    allow(lease).to receive(:release!)
    allow(lease).to receive(:state_released?).and_return(false)
  end

  describe "Sidekiq options" do
    it "retry: false が設定されている" do
      expect(described_class.sidekiq_options["retry"]).to be false
    end

    it "queue: live_trading が設定されている" do
      expect(described_class.sidekiq_options["queue"]).to eq(:live_trading)
    end
  end

  describe "#perform(session_id)" do
    context "step 1-4 全成功(現時点 3.3-9a で実装済の範囲)" do
      it "process_manager.acquire_lease! を session + worker_instance_id で呼ぶ" do
        worker.perform(session.id)

        expect(process_manager).to have_received(:acquire_lease!).with(
          session: an_object_having_attributes(id: session.id),
          worker_instance_id: a_kind_of(String)
        )
      end

      it "session の status は starting のまま(step 13 mark_running は 3.3-9d で実装)" do
        worker.perform(session.id)
        expect(session.reload.state_starting?).to be true
      end
    end

    context "step 1 失敗(session_id 不在)" do
      it "ActiveRecord::RecordNotFound を raise する" do
        expect { worker.perform(99_999_999) }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "session 不在のため failed_to_start に遷移する Session が存在しない" do
        expect { worker.perform(99_999_999) }.to raise_error(ActiveRecord::RecordNotFound)
        expect(LiveTrading::Session.where(status: "failed_to_start").count).to eq(0)
      end
    end

    context "step 2 失敗(strategy_definition_id 不整合)" do
      let(:other_definition) do
        Strategy::Definition.create!(name: "Other Worker Strat", market_type: "futures", status: "active")
      end
      let(:other_revision) do
        Strategy::Revision.create!(
          strategy_definition: other_definition,
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

      before do
        session.update_column(:strategy_revision_id, other_revision.id)
      end

      it "ArgumentError を raise する" do
        expect { worker.perform(session.id) }.to raise_error(ArgumentError, /strategy_definition_id mismatch/)
      end

      it "session.mark_failed_to_start! が呼ばれる(reason に error class が含まれる)" do
        expect { worker.perform(session.id) }.to raise_error(ArgumentError)
        session.reload
        expect(session.state_failed_to_start?).to be true
        expect(session.failure_reason).to include("ArgumentError")
      end

      it "lease.release! を呼ばない(軽微 1: lease 未取得のため)" do
        expect { worker.perform(session.id) }.to raise_error(ArgumentError)
        expect(lease).not_to have_received(:release!)
      end

      it "process_manager.acquire_lease! を呼ばない" do
        expect { worker.perform(session.id) }.to raise_error(ArgumentError)
        expect(process_manager).not_to have_received(:acquire_lease!)
      end
    end

    context "step 2 失敗(revision.acceptable_for_live? が false)" do
      before do
        revision.update_column(:status, "draft")
      end

      it "ArgumentError を raise + failed_to_start 遷移" do
        expect { worker.perform(session.id) }.to raise_error(ArgumentError, /not acceptable for live/)
        expect(session.reload.state_failed_to_start?).to be true
      end
    end

    context "step 2 失敗(revision.uses_live_forbidden_input が true)" do
      before do
        revision.update_column(:uses_live_forbidden_input, true)
      end

      it "ArgumentError を raise + failed_to_start 遷移" do
        expect { worker.perform(session.id) }.to raise_error(ArgumentError, /uses_live_forbidden_input/)
        expect(session.reload.state_failed_to_start?).to be true
      end
    end

    context "step 3 失敗(risk_policy 不在)" do
      before do
        # FK 制約があるため update_column での破壊は不可.Risk::Policy.find を直接 stub する.
        allow(Risk::Policy).to receive(:find).with(session.risk_policy_id)
          .and_raise(ActiveRecord::RecordNotFound, "Risk::Policy not found")
      end

      it "ActiveRecord::RecordNotFound を raise + failed_to_start 遷移" do
        expect { worker.perform(session.id) }.to raise_error(ActiveRecord::RecordNotFound)
        expect(session.reload.state_failed_to_start?).to be true
      end

      it "lease.release! を呼ばない(軽微 1: lease 未取得のため)" do
        expect { worker.perform(session.id) }.to raise_error(ActiveRecord::RecordNotFound)
        expect(lease).not_to have_received(:release!)
      end
    end

    context "step 4 失敗(ActiveLeaseError)" do
      before do
        allow(process_manager).to receive(:acquire_lease!)
          .and_raise(LiveTrading::SessionLease::ActiveLeaseError, "already active")
      end

      it "ActiveLeaseError を raise + failed_to_start 遷移" do
        expect { worker.perform(session.id) }
          .to raise_error(LiveTrading::SessionLease::ActiveLeaseError)
        expect(session.reload.state_failed_to_start?).to be true
      end

      it "lease.release! を呼ばない(軽微 1: lease 取得失敗のため対象なし)" do
        expect { worker.perform(session.id) }
          .to raise_error(LiveTrading::SessionLease::ActiveLeaseError)
        expect(lease).not_to have_received(:release!)
      end
    end

    context "session が既に terminal 状態(stopped)で step 2 失敗誘発時(冪等性)" do
      before do
        session.update_column(:status, "stopped")
        revision.update_column(:status, "draft")
      end

      it "ArgumentError を raise するが mark_failed_to_start! は呼ばない(terminal 冪等性)" do
        expect { worker.perform(session.id) }.to raise_error(ArgumentError, /not acceptable for live/)
        expect(session.reload.state_stopped?).to be true
      end
    end

    context "worker_instance_id 生成" do
      it "perform 実行時に毎回生成される(jid なしの場合 manual- prefix 付き)" do
        worker.perform(session.id)

        expect(process_manager).to have_received(:acquire_lease!).with(
          a_hash_including(worker_instance_id: a_string_starting_with("manual-"))
        )
      end
    end
  end
end
