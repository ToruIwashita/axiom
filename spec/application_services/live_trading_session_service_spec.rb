require "rails_helper"

RSpec.describe ApplicationServices::LiveTradingSessionService do
  let(:service) { described_class.new }
  let(:worker_class) do
    Class.new do
      def self.perform_async(_session_id); end
    end
  end

  before do
    stub_const("LiveTradingWorker", worker_class)
    allow(worker_class).to receive(:perform_async)
  end

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

  let(:start_session_args) do
    {
      strategy_definition_id: definition.id,
      strategy_revision_id: revision.id,
      risk_policy_id: risk_policy.id,
      symbol: "BTCUSDT",
      leverage: 10,
      margin_mode: "isolated",
      position_mode: "one_way_mode",
      asset_mode: "single",
      margin_coin: "USDT",
      emergency_stop_mode: "cancel_only"
    }
  end

  describe "#start_session" do
    subject { service.start_session(**start_session_args) }

    context "整合検証 + 受入条件全て通過" do
      it "starting 状態の Session を作成する" do
        session = subject

        expect(session).to be_a(LiveTrading::Session)
        expect(session).to be_persisted
        expect(session.state_starting?).to be true
        expect(session.symbol).to eq("BTCUSDT")
        expect(session.leverage).to eq(10)
        expect(session.strategy_definition_id).to eq(definition.id)
        expect(session.strategy_revision_id).to eq(revision.id)
        expect(session.risk_policy_id).to eq(risk_policy.id)
      end

      it "LiveTradingWorker.perform_async を session.id で呼ぶ" do
        session = subject
        expect(worker_class).to have_received(:perform_async).with(session.id)
      end
    end

    context "Revision の strategy_definition_id が指定 definition_id と異なる場合" do
      let(:other_definition) do
        Strategy::Definition.create!(name: "Other Strat", market_type: "futures", status: "active")
      end

      before do
        start_session_args[:strategy_definition_id] = other_definition.id
      end

      it "ArgumentError を raise する(Session 未作成)" do
        expect { subject }.to raise_error(ArgumentError, /strategy_definition_id mismatch/)
        expect(LiveTrading::Session.count).to eq(0)
        expect(worker_class).not_to have_received(:perform_async)
      end
    end

    context "Revision が acceptable_for_live? を満たさない場合(status=draft)" do
      before do
        revision.update_column(:status, "draft")
      end

      it "ArgumentError を raise する(Session 未作成)" do
        expect { subject }.to raise_error(ArgumentError, /not acceptable for live/)
        expect(LiveTrading::Session.count).to eq(0)
        expect(worker_class).not_to have_received(:perform_async)
      end
    end

    context "Revision の uses_live_forbidden_input が true の場合" do
      before do
        revision.update_column(:uses_live_forbidden_input, true)
      end

      it "ArgumentError を raise する(Session 未作成)" do
        expect { subject }.to raise_error(ArgumentError, /uses_live_forbidden_input/)
        expect(LiveTrading::Session.count).to eq(0)
        expect(worker_class).not_to have_received(:perform_async)
      end
    end
  end

  describe "#stop" do
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

    subject { service.stop(session_id: session.id, mode: "cancel_and_market_close") }

    it "session を stopping 状態に遷移させる" do
      result = subject

      result.reload
      expect(result.state_stopping?).to be true
    end

    it "emergency_stop_mode を更新する" do
      result = subject

      result.reload
      expect(result.emergency_stop_mode).to eq("cancel_and_market_close")
    end

    it "更新後の Session を返す" do
      result = subject
      expect(result).to be_a(LiveTrading::Session)
      expect(result.id).to eq(session.id)
    end

    context "session が running 以外(starting)の場合" do
      before do
        session.update_column(:status, "starting")
      end

      it "InvalidTransitionError を raise する" do
        expect { subject }.to raise_error(LiveTrading::Session::InvalidTransitionError)
      end
    end
  end

  describe "#emergency_stop" do
    let(:running_session_btc) do
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
    let(:running_session_eth) do
      LiveTrading::Session.create!(
        strategy_definition: definition,
        strategy_revision: revision,
        risk_policy: risk_policy,
        symbol: "ETHUSDT",
        leverage: 5,
        margin_mode: "isolated",
        position_mode: "one_way_mode",
        asset_mode: "single",
        margin_coin: "USDT",
        emergency_stop_mode: "cancel_only",
        status: "running"
      )
    end
    let(:starting_session) do
      LiveTrading::Session.create!(
        strategy_definition: definition,
        strategy_revision: revision,
        risk_policy: risk_policy,
        symbol: "SOLUSDT",
        leverage: 5,
        margin_mode: "isolated",
        position_mode: "one_way_mode",
        asset_mode: "single",
        margin_coin: "USDT",
        emergency_stop_mode: "cancel_only",
        status: "starting"
      )
    end

    subject { service.emergency_stop(mode: "cancel_and_market_close") }

    before do
      running_session_btc
      running_session_eth
      starting_session
    end

    it "running 状態の全 Session を stopping に遷移させる(starting は対象外)" do
      sessions = subject

      expect(sessions.size).to eq(2)
      expect(sessions.map(&:id)).to contain_exactly(running_session_btc.id, running_session_eth.id)
      expect(running_session_btc.reload.state_stopping?).to be true
      expect(running_session_eth.reload.state_stopping?).to be true
      expect(starting_session.reload.state_starting?).to be true
    end

    it "対象 Session の emergency_stop_mode を一括更新する" do
      subject
      expect(running_session_btc.reload.emergency_stop_mode).to eq("cancel_and_market_close")
      expect(running_session_eth.reload.emergency_stop_mode).to eq("cancel_and_market_close")
    end

    context "running セッションが 0 件の場合" do
      before do
        running_session_btc.update_column(:status, "stopped")
        running_session_eth.update_column(:status, "stopped")
      end

      it "空配列を返す" do
        expect(subject).to eq([])
      end
    end
  end
end
