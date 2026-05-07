require "rails_helper"

RSpec.describe Domain::LiveTradingProcessManager do
  let(:fixed_now) { Time.utc(2026, 5, 7, 12, 0, 0) }
  let(:clock) { -> { fixed_now } }
  let(:manager) { described_class.new(clock: clock) }

  let(:definition) do
    Strategy::Definition.create!(name: "PM Live Strat", market_type: "futures", status: "active")
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
      name: "PM Default Policy",
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

  describe "#acquire_lease!" do
    subject { manager.acquire_lease!(session: session, worker_instance_id: "worker-001") }

    it "LiveTrading::SessionLease.acquire! を delegate して取得する" do
      expect(LiveTrading::SessionLease).to receive(:acquire!).with(
        session_id: session.id,
        worker_instance_id: "worker-001",
        acquired_at: fixed_now
      ).and_call_original

      lease = subject

      expect(lease).to be_a(LiveTrading::SessionLease)
      expect(lease.live_trading_session_id).to eq(session.id)
      expect(lease.worker_instance_id).to eq("worker-001")
      expect(lease.acquired_at).to eq(fixed_now)
      expect(lease.expires_at).to eq(fixed_now + LiveTrading::SessionLease::DEFAULT_TTL_SECONDS)
      expect(lease.state_active?).to be true
    end
  end

  describe "#pulse_heartbeat!" do
    subject { manager.pulse_heartbeat!(session: session, worker_instance_id: "worker-001") }

    it "LiveTrading::SessionHeartbeat.pulse! を delegate して打鍵する" do
      expect(LiveTrading::SessionHeartbeat).to receive(:pulse!).with(
        session_id: session.id,
        worker_instance_id: "worker-001",
        pulsed_at: fixed_now
      ).and_call_original

      heartbeat = subject

      expect(heartbeat).to be_a(LiveTrading::SessionHeartbeat)
      expect(heartbeat.live_trading_session_id).to eq(session.id)
      expect(heartbeat.worker_instance_id).to eq("worker-001")
      expect(heartbeat.pulsed_at).to eq(fixed_now)
    end
  end

  describe "#renew_lease!" do
    let(:lease) do
      LiveTrading::SessionLease.acquire!(
        session_id: session.id,
        worker_instance_id: "worker-001",
        acquired_at: fixed_now - 120
      )
    end

    subject { manager.renew_lease!(lease: lease) }

    it "lease の expires_at を clock 基準で TTL 分延長する" do
      subject

      lease.reload
      expect(lease.expires_at).to eq(fixed_now + LiveTrading::SessionLease::DEFAULT_TTL_SECONDS)
      expect(lease.renewed_at).to eq(fixed_now)
    end

    it "更新後の lease を返す" do
      result = subject
      expect(result).to be_a(LiveTrading::SessionLease)
      expect(result.id).to eq(lease.id)
    end
  end

  describe "#release_lease!" do
    let(:lease) do
      LiveTrading::SessionLease.acquire!(
        session_id: session.id,
        worker_instance_id: "worker-001",
        acquired_at: fixed_now
      )
    end

    subject { manager.release_lease!(lease: lease) }

    it "lease を released 状態に遷移させる" do
      subject

      lease.reload
      expect(lease.state_released?).to be true
    end

    it "解放後の lease を返す" do
      result = subject
      expect(result).to be_a(LiveTrading::SessionLease)
      expect(result.id).to eq(lease.id)
    end
  end

  describe "#signal_kill_switch?" do
    subject { manager.signal_kill_switch?(session: session) }

    context "session.status=stopping の場合" do
      before do
        session.update_column(:status, "stopping")
      end

      it "true を返す" do
        expect(subject).to be true
      end
    end

    context "session.status=running の場合" do
      before do
        session.update_column(:status, "running")
      end

      it "false を返す" do
        expect(subject).to be false
      end
    end

    context "session.status=starting の場合" do
      it "false を返す(stopping 以外)" do
        expect(subject).to be false
      end
    end

    context "session.status=stopped の場合" do
      before do
        session.update_column(:status, "stopped")
      end

      it "false を返す(終端状態)" do
        expect(subject).to be false
      end
    end
  end
end
