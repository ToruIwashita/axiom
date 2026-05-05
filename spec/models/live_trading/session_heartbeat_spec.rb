require "rails_helper"

RSpec.describe LiveTrading::SessionHeartbeat, type: :model do
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
      status: "running"
    )
  end

  describe "validations" do
    let(:base_attributes) do
      {
        live_trading_session: session,
        worker_instance_id: "worker-001",
        pulsed_at: Time.current
      }
    end

    subject { described_class.new(attributes) }

    context "必須属性が全て揃っている場合" do
      let(:attributes) { base_attributes }

      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end

    %i[worker_instance_id pulsed_at].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { base_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end
  end

  describe ".pulse!" do
    let(:pulsed_at) { Time.utc(2026, 5, 5, 12, 0, 0) }

    subject do
      described_class.pulse!(
        session_id: session.id,
        worker_instance_id: "worker-001",
        pulsed_at: pulsed_at
      )
    end

    it "Heartbeat レコードを作成する" do
      expect { subject }.to change(described_class, :count).by(1)
      result = described_class.last
      expect(result.live_trading_session_id).to eq(session.id)
      expect(result.worker_instance_id).to eq("worker-001")
      expect(result.pulsed_at).to eq(pulsed_at)
    end
  end

  describe ".recent scope" do
    before do
      [ 10, 5, 3, 1 ].each_with_index do |minutes_ago, i|
        described_class.create!(
          live_trading_session: session,
          worker_instance_id: "worker-#{i}",
          pulsed_at: Time.current - minutes_ago.minutes
        )
      end
    end

    it "pulsed_at 降順で最大 N 件返す(limit=2 の場合)" do
      result = described_class.recent(2)
      expect(result.count).to eq(2)
      expect(result.first.pulsed_at).to be > result.second.pulsed_at
    end

    it "pulsed_at 降順で最大 N 件返す(limit=10 の場合は全件)" do
      result = described_class.recent(10)
      expect(result.count).to eq(4)
    end
  end

  describe "関連" do
    let(:heartbeat) do
      described_class.create!(
        live_trading_session: session,
        worker_instance_id: "worker-001",
        pulsed_at: Time.current
      )
    end

    it "live_trading_session に belongs_to で繋がる" do
      expect(heartbeat.live_trading_session).to eq(session)
    end
  end
end
