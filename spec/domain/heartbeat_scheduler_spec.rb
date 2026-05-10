require "rails_helper"

RSpec.describe Domain::HeartbeatScheduler do
  let(:process_manager) { instance_double(Domain::LiveTradingProcessManager) }
  let(:logger) { instance_double(Logger, warn: nil, info: nil, error: nil, debug: nil) }
  let(:clock_value) { [ 1000.0 ] }
  let(:monotonic_clock) { -> { clock_value.first } }
  let(:scheduler) do
    described_class.new(
      process_manager: process_manager,
      monotonic_clock: monotonic_clock,
      logger: logger,
      heartbeat_interval_seconds: 60,
      lease_renew_interval_seconds: 120
    )
  end
  let(:session) { double("Session") }
  let(:lease) { double("Lease") }
  let(:worker_instance_id) { "worker-001" }

  before do
    allow(process_manager).to receive(:pulse_heartbeat!)
    allow(process_manager).to receive(:renew_lease!)
  end

  describe "#pulse_heartbeat_if_due" do
    context "初回呼出(@last_heartbeat_at が nil)" do
      it "process_manager.pulse_heartbeat! を呼ぶ" do
        scheduler.pulse_heartbeat_if_due(session: session, worker_instance_id: worker_instance_id)
        expect(process_manager).to have_received(:pulse_heartbeat!).with(session: session, worker_instance_id: worker_instance_id)
      end
    end

    context "前回 pulse から 60 秒未経過" do
      before do
        scheduler.pulse_heartbeat_if_due(session: session, worker_instance_id: worker_instance_id)
        clock_value[0] = 1030.0 # 30 秒経過
      end

      it "pulse_heartbeat! を呼ばない" do
        scheduler.pulse_heartbeat_if_due(session: session, worker_instance_id: worker_instance_id)
        expect(process_manager).to have_received(:pulse_heartbeat!).once
      end
    end

    context "前回 pulse から 60 秒以上経過" do
      before do
        scheduler.pulse_heartbeat_if_due(session: session, worker_instance_id: worker_instance_id)
        clock_value[0] = 1061.0 # 61 秒経過
      end

      it "pulse_heartbeat! を再度呼ぶ" do
        scheduler.pulse_heartbeat_if_due(session: session, worker_instance_id: worker_instance_id)
        expect(process_manager).to have_received(:pulse_heartbeat!).twice
      end
    end

    context "process_manager.pulse_heartbeat! が raise した場合" do
      before do
        allow(process_manager).to receive(:pulse_heartbeat!)
          .and_raise(StandardError, "DB conn lost")
      end

      it "logger.warn 落とし + 再 raise しない(main loop を止めない)" do
        expect {
          scheduler.pulse_heartbeat_if_due(session: session, worker_instance_id: worker_instance_id)
        }.not_to raise_error
        expect(logger).to have_received(:warn).with(/pulse_heartbeat! failed.*DB conn lost/)
      end
    end

    context "raise メッセージに credentials が含まれる場合" do
      before do
        allow(process_manager).to receive(:pulse_heartbeat!)
          .and_raise(StandardError, "Faraday error: api_key=ABC123")
      end

      it "logger.warn メッセージは sanitize される" do
        scheduler.pulse_heartbeat_if_due(session: session, worker_instance_id: worker_instance_id)
        expect(logger).to have_received(:warn).with(/api_key=\[FILTERED\]/)
      end
    end
  end

  describe "#renew_lease_if_due" do
    context "初回呼出 + lease 指定あり" do
      it "process_manager.renew_lease! を呼ぶ" do
        scheduler.renew_lease_if_due(lease: lease)
        expect(process_manager).to have_received(:renew_lease!).with(lease: lease)
      end
    end

    context "lease が nil の場合" do
      it "renew_lease! を呼ばない / raise しない" do
        scheduler.renew_lease_if_due(lease: nil)
        expect(process_manager).not_to have_received(:renew_lease!)
      end
    end

    context "前回 renew から 120 秒未経過" do
      before do
        scheduler.renew_lease_if_due(lease: lease)
        clock_value[0] = 1100.0 # 100 秒経過
      end

      it "renew_lease! を呼ばない" do
        scheduler.renew_lease_if_due(lease: lease)
        expect(process_manager).to have_received(:renew_lease!).once
      end
    end

    context "前回 renew から 120 秒以上経過" do
      before do
        scheduler.renew_lease_if_due(lease: lease)
        clock_value[0] = 1121.0 # 121 秒経過
      end

      it "renew_lease! を再度呼ぶ" do
        scheduler.renew_lease_if_due(lease: lease)
        expect(process_manager).to have_received(:renew_lease!).twice
      end
    end

    context "process_manager.renew_lease! が raise した場合" do
      before do
        allow(process_manager).to receive(:renew_lease!)
          .and_raise(StandardError, "lease conflict")
      end

      it "logger.warn 落とし + 再 raise しない" do
        expect { scheduler.renew_lease_if_due(lease: lease) }.not_to raise_error
        expect(logger).to have_received(:warn).with(/renew_lease! failed.*lease conflict/)
      end
    end
  end

  describe "#reset" do
    it "pulse / renew の last_run_at をクリアし,次回呼出が即実行される" do
      scheduler.pulse_heartbeat_if_due(session: session, worker_instance_id: worker_instance_id)
      scheduler.renew_lease_if_due(lease: lease)

      scheduler.reset
      # clock 進めず再呼出 → reset 後初回扱いで実行される
      scheduler.pulse_heartbeat_if_due(session: session, worker_instance_id: worker_instance_id)
      scheduler.renew_lease_if_due(lease: lease)

      expect(process_manager).to have_received(:pulse_heartbeat!).twice
      expect(process_manager).to have_received(:renew_lease!).twice
    end
  end
end
