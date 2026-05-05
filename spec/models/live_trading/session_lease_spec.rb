require "rails_helper"

RSpec.describe LiveTrading::SessionLease, type: :model do
  let(:definition) do
    Strategy::Definition.create!(name: "Live Strat", market_type: "futures", status: "active")
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
      name: "Default Policy",
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
  let(:other_session) do
    LiveTrading::Session.create!(
      strategy_definition: definition,
      strategy_revision: revision,
      risk_policy: risk_policy,
      symbol: "ETHUSDT",
      leverage: 5,
      margin_mode: "crossed",
      position_mode: "one_way_mode",
      asset_mode: "single",
      margin_coin: "USDT",
      emergency_stop_mode: "cancel_only",
      status: "starting"
    )
  end

  describe "validations" do
    let(:base_attributes) do
      {
        live_trading_session: session,
        lease_token: SecureRandom.uuid,
        worker_instance_id: "worker-001",
        acquired_at: Time.current,
        renewed_at: Time.current,
        expires_at: Time.current + 300,
        status: "active"
      }
    end

    subject { described_class.new(attributes) }

    context "必須属性が全て揃っている場合" do
      let(:attributes) { base_attributes }

      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end

    %i[lease_token worker_instance_id acquired_at expires_at status].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { base_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end

    context "同じ live_trading_session_id で 2 件目を作成しようとする場合" do
      before { described_class.create!(base_attributes) }

      let(:attributes) { base_attributes.merge(lease_token: SecureRandom.uuid) }

      it "1 対 1 制約により valid? が false" do
        expect(subject).not_to be_valid
        expect(subject.errors[:live_trading_session_id]).to be_present
      end
    end

    context "lease_token が既存と重複する場合" do
      let(:duplicated_token) { SecureRandom.uuid }
      before do
        described_class.create!(base_attributes.merge(lease_token: duplicated_token))
      end

      let(:attributes) do
        base_attributes.merge(live_trading_session: other_session, lease_token: duplicated_token)
      end

      it "valid? が false を返し lease_token にエラー" do
        expect(subject).not_to be_valid
        expect(subject.errors[:lease_token]).to be_present
      end
    end
  end

  describe "enums" do
    let(:base_attributes) do
      {
        live_trading_session: session,
        lease_token: SecureRandom.uuid,
        worker_instance_id: "worker-001",
        acquired_at: Time.current,
        expires_at: Time.current + 300,
        status: "active"
      }
    end

    subject { described_class.new(base_attributes) }

    context "status enum が 3 値定義されている" do
      it "active/released/expired を全て受理する" do
        %w[active released expired].each do |s|
          subject.status = s
          expect(subject.status).to eq(s)
        end
      end

      it "未定義の status は ArgumentError" do
        expect { subject.status = "unknown" }.to raise_error(ArgumentError)
      end
    end
  end

  describe ".acquire!" do
    let(:now) { Time.utc(2026, 5, 5, 12, 0, 0) }

    context "TTL デフォルト 300 秒で acquire する場合" do
      subject do
        described_class.acquire!(session_id: session.id, worker_instance_id: "worker-001", acquired_at: now)
      end

      it "active 状態の Lease が作成され expires_at が acquired_at + 300 秒" do
        result = subject
        expect(result).to be_state_active
        expect(result.acquired_at).to eq(now)
        expect(result.expires_at).to eq(now + 300)
        expect(result.lease_token).to be_present
        expect(result.worker_instance_id).to eq("worker-001")
      end
    end

    context "TTL 60 秒を明示指定する場合" do
      subject do
        described_class.acquire!(
          session_id: session.id,
          worker_instance_id: "worker-002",
          ttl_seconds: 60,
          acquired_at: now
        )
      end

      it "expires_at が acquired_at + 60 秒" do
        expect(subject.expires_at).to eq(now + 60)
      end
    end
  end

  describe "#renew!" do
    let(:lease) do
      described_class.acquire!(
        session_id: session.id,
        worker_instance_id: "worker-001",
        acquired_at: Time.current
      )
    end
    let(:new_expires_at) { Time.utc(2026, 5, 5, 13, 0, 0) }
    let(:renewed_at) { Time.utc(2026, 5, 5, 12, 30, 0) }

    it "expires_at と renewed_at が更新される" do
      lease.renew!(new_expires_at: new_expires_at, renewed_at: renewed_at)
      expect(lease.expires_at).to eq(new_expires_at)
      expect(lease.renewed_at).to eq(renewed_at)
    end
  end

  describe "#release!" do
    let(:lease) do
      described_class.acquire!(
        session_id: session.id,
        worker_instance_id: "worker-001",
        acquired_at: Time.current
      )
    end

    it "released 状態に遷移する" do
      lease.release!
      expect(lease).to be_state_released
    end
  end

  describe "#expired?" do
    let(:lease) do
      described_class.create!(
        live_trading_session: session,
        lease_token: SecureRandom.uuid,
        worker_instance_id: "worker-001",
        acquired_at: Time.utc(2026, 5, 5, 11, 0, 0),
        expires_at: Time.utc(2026, 5, 5, 12, 0, 0),
        status: "active"
      )
    end

    context "now が expires_at 以前の場合" do
      it "false を返す" do
        expect(lease.expired?(now: Time.utc(2026, 5, 5, 11, 30, 0))).to be false
      end
    end

    context "now が expires_at を超えた場合" do
      it "true を返す" do
        expect(lease.expired?(now: Time.utc(2026, 5, 5, 12, 1, 0))).to be true
      end
    end
  end

  describe ".active scope" do
    let(:now) { Time.utc(2026, 5, 5, 12, 0, 0) }

    before do
      described_class.create!(
        live_trading_session: session,
        lease_token: SecureRandom.uuid,
        worker_instance_id: "active-worker",
        acquired_at: now,
        expires_at: now + 300,
        status: "active"
      )
      described_class.create!(
        live_trading_session: other_session,
        lease_token: SecureRandom.uuid,
        worker_instance_id: "expired-worker",
        acquired_at: now - 600,
        expires_at: now - 60,
        status: "active"
      )
    end

    it "expires_at が現在時刻より未来の active レコードのみを返す" do
      result = described_class.active(now: now)
      expect(result.pluck(:worker_instance_id)).to contain_exactly("active-worker")
    end
  end
end
