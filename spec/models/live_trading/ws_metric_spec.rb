require "rails_helper"

RSpec.describe LiveTrading::WsMetric, type: :model do
  let(:definition) { Strategy::Definition.create!(name: "WsM Strat", market_type: "futures", status: "active") }
  let(:revision) do
    Strategy::Revision.create!(
      strategy_definition: definition,
      revision_number: 1,
      script_content: "class S < Domain::TradingScriptBase; def on_tick(ctx, candle); end; end",
      script_entrypoint: "S",
      status: "approved",
      ast_validation_status: "passed",
      uses_live_forbidden_input: false,
      ai_filter_enabled: false,
      ai_sizing_enabled: false
    )
  end
  let(:risk_policy) do
    Risk::Policy.create!(
      name: "WsM Policy",
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
  let(:base_attributes) do
    {
      session: session,
      detected_at: Time.current,
      public_count_since_start: 1,
      private_count_since_start: 0,
      delta_public: 1,
      delta_private: 0,
      worker_instance_id: "test-worker-instance"
    }
  end

  describe "validations" do
    subject { described_class.new(base_attributes) }

    context "全必須属性が揃っている場合" do
      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end

    %i[detected_at public_count_since_start private_count_since_start delta_public delta_private worker_instance_id].each do |attr|
      context "#{attr} が nil の場合" do
        it "valid? が false を返す" do
          subject.assign_attributes(attr => nil)
          expect(subject).not_to be_valid
        end
      end
    end

    # 高-2 反映: validation 緩和(>= 0 制約は外す / Worker 跨ぎ delta クランプは Worker 側で実施)
    context "delta_public が負値の場合(Worker 跨ぎ補正前提で許容)" do
      it "valid? が true を返す(>= 0 制約なし / numericality only_integer のみ)" do
        subject.assign_attributes(delta_public: -1)
        expect(subject).to be_valid
      end
    end

    context "public_count_since_start が小数の場合" do
      it "valid? が false を返す(only_integer)" do
        subject.assign_attributes(public_count_since_start: 1.5)
        expect(subject).not_to be_valid
      end
    end

    # 低-7 反映: source_event / target_ws の inclusion + nil 許容
    context "source_event が nil の場合" do
      it "valid? が true を返す(allow_nil)" do
        subject.assign_attributes(source_event: nil)
        expect(subject).to be_valid
      end
    end

    context "source_event が SOURCE_EVENTS 外の場合" do
      it "valid? が false を返す" do
        subject.assign_attributes(source_event: "unknown")
        expect(subject).not_to be_valid
      end
    end

    %w[close error heartbeat_timeout].each do |event|
      context "source_event が #{event} の場合" do
        it "valid? が true を返す" do
          subject.assign_attributes(source_event: event)
          expect(subject).to be_valid
        end
      end
    end

    context "target_ws が TARGET_WS 外の場合" do
      it "valid? が false を返す" do
        subject.assign_attributes(target_ws: "unknown")
        expect(subject).not_to be_valid
      end
    end

    %w[public private both].each do |target|
      context "target_ws が #{target} の場合" do
        it "valid? が true を返す" do
          subject.assign_attributes(target_ws: target)
          expect(subject).to be_valid
        end
      end
    end

    context "worker_instance_id が 64 文字を超える場合" do
      it "valid? が false を返す" do
        subject.assign_attributes(worker_instance_id: "x" * 65)
        expect(subject).not_to be_valid
      end
    end
  end

  describe "associations" do
    context "session(belongs_to)" do
      it "親 session との関連が成立する" do
        metric = described_class.create!(base_attributes)
        expect(metric.session).to eq(session)
      end
    end
  end

  describe ".recent" do
    subject { described_class.recent(2) }

    context "3 件存在する場合" do
      let!(:m_old) { described_class.create!(base_attributes.merge(detected_at: 3.minutes.ago)) }
      let!(:m_mid) { described_class.create!(base_attributes.merge(detected_at: 2.minutes.ago)) }
      let!(:m_new) { described_class.create!(base_attributes.merge(detected_at: 1.minute.ago)) }

      it "detected_at 降順で limit 件を返す" do
        expect(subject.to_a).to eq([ m_new, m_mid ])
      end
    end
  end

  describe ".by_worker" do
    subject { described_class.by_worker("worker-A") }

    let!(:m_a1) { described_class.create!(base_attributes.merge(worker_instance_id: "worker-A")) }
    let!(:m_b1) { described_class.create!(base_attributes.merge(worker_instance_id: "worker-B")) }
    let!(:m_a2) { described_class.create!(base_attributes.merge(worker_instance_id: "worker-A")) }

    it "指定 worker_instance_id のレコードのみ返す" do
      expect(subject.to_a).to match_array([ m_a1, m_a2 ])
    end
  end

  describe "Worker 寿命内累積仕様" do
    context "Worker 再起動跨ぎで public_count_since_start = 0 から再開する場合" do
      let!(:m_first_worker) { described_class.create!(base_attributes.merge(worker_instance_id: "worker-A", public_count_since_start: 5)) }
      let(:m_second_worker) { described_class.new(base_attributes.merge(worker_instance_id: "worker-B", public_count_since_start: 0, delta_public: 0)) }

      it "新 Worker の public_count_since_start = 0 でも valid"  do
        expect(m_second_worker).to be_valid
      end
    end
  end
end
