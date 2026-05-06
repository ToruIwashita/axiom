require "rails_helper"

RSpec.describe LiveTrading::Session, type: :model do
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
  let(:base_attributes) do
    {
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
    }
  end

  describe "validations" do
    subject { described_class.new(attributes) }

    context "必須属性が全て揃っている場合" do
      let(:attributes) { base_attributes }

      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end

    %i[symbol leverage margin_mode position_mode asset_mode margin_coin emergency_stop_mode status].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { base_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end

    context "leverage が 0 以下の場合" do
      let(:attributes) { base_attributes.merge(leverage: 0) }

      it "valid? が false を返す" do
        expect(subject).not_to be_valid
        expect(subject.errors[:leverage]).to be_present
      end
    end

    context "leverage が 125 を超える場合" do
      let(:attributes) { base_attributes.merge(leverage: 126) }

      it "valid? が false を返す" do
        expect(subject).not_to be_valid
        expect(subject.errors[:leverage]).to be_present
      end
    end
  end

  describe "enums" do
    subject { described_class.new(base_attributes) }

    context "status enum が 8 値定義されている" do
      it "starting/reconciling/running/cooling_down/stopping/stopped/failed_to_start/halted を全て受理する" do
        %w[starting reconciling running cooling_down stopping stopped failed_to_start halted].each do |s|
          subject.status = s
          expect(subject.status).to eq(s)
        end
      end

      it "未定義の status は ArgumentError" do
        expect { subject.status = "unknown" }.to raise_error(ArgumentError)
      end
    end

    context "margin_mode enum が 2 値定義されている" do
      it "isolated/crossed を受理し他は ArgumentError" do
        subject.margin_mode = "crossed"
        expect(subject.margin_mode).to eq("crossed")
        expect { subject.margin_mode = "invalid" }.to raise_error(ArgumentError)
      end
    end

    context "position_mode enum が 2 値定義されている" do
      it "one_way_mode/hedge_mode を受理する" do
        subject.position_mode = "hedge_mode"
        expect(subject.position_mode).to eq("hedge_mode")
      end
    end

    context "asset_mode enum が 2 値定義されている" do
      it "single/union を受理する" do
        subject.asset_mode = "union"
        expect(subject.asset_mode).to eq("union")
      end
    end

    context "emergency_stop_mode enum が 3 値定義されている" do
      it "cancel_only/cancel_and_market_close/cancel_and_reduce_only を受理する" do
        %w[cancel_only cancel_and_market_close cancel_and_reduce_only].each do |m|
          subject.emergency_stop_mode = m
          expect(subject.emergency_stop_mode).to eq(m)
        end
      end
    end
  end

  describe "状態遷移メソッド" do
    let(:session) { described_class.create!(base_attributes) }

    describe "#start_reconciling!" do
      it "starting → reconciling に遷移する" do
        session.start_reconciling!
        expect(session).to be_state_reconciling
      end
    end

    describe "#start_running!" do
      let(:started_at) { Time.utc(2026, 5, 5, 12, 0, 0) }

      it "reconciling → running に遷移し started_at が設定される" do
        session.update!(status: "reconciling")
        session.start_running!(started_at: started_at)
        expect(session).to be_state_running
        expect(session.started_at).to eq(started_at)
      end
    end

    describe "#start_cooling_down!" do
      it "running → cooling_down に遷移する" do
        session.update!(status: "running")
        session.start_cooling_down!
        expect(session).to be_state_cooling_down
      end
    end

    describe "#resume_from_cooling!" do
      it "cooling_down → running に遷移する" do
        session.update!(status: "cooling_down")
        session.resume_from_cooling!
        expect(session).to be_state_running
      end
    end

    describe "#start_stopping!" do
      it "running → stopping に遷移する" do
        session.update!(status: "running")
        session.start_stopping!
        expect(session).to be_state_stopping
      end

      it "cooling_down → stopping に遷移する" do
        session.update!(status: "cooling_down")
        session.start_stopping!
        expect(session).to be_state_stopping
      end
    end

    describe "#mark_stopped!" do
      let(:stopped_at) { Time.utc(2026, 5, 5, 13, 0, 0) }

      it "stopping → stopped に遷移し stopped_at が設定される" do
        session.update!(status: "stopping")
        session.mark_stopped!(stopped_at: stopped_at)
        expect(session).to be_state_stopped
        expect(session.stopped_at).to eq(stopped_at)
      end
    end

    describe "#mark_failed_to_start!" do
      it "starting → failed_to_start に遷移し failure_reason が設定される" do
        session.mark_failed_to_start!(reason: "bootstrap step 4 failed")
        expect(session).to be_state_failed_to_start
        expect(session.failure_reason).to eq("bootstrap step 4 failed")
      end

      it "failure_reason は 10_000 文字を超えると truncate される" do
        long_reason = "x" * 11_000
        session.mark_failed_to_start!(reason: long_reason)
        expect(session.failure_reason.length).to eq(10_000)
      end
    end

    describe "#mark_halted!" do
      it "running → halted に遷移し failure_reason が設定される" do
        session.update!(status: "running")
        session.mark_halted!(reason: "max_drawdown exceeded")
        expect(session).to be_state_halted
        expect(session.failure_reason).to eq("max_drawdown exceeded")
      end
    end

    describe "状態遷移ガード(レビュー Step R-1: 不正パス)" do
      describe "#start_reconciling! は starting 以外から呼ぶと InvalidTransitionError" do
        %w[reconciling running cooling_down stopping stopped failed_to_start halted].each do |bad_status|
          it "from #{bad_status}: raise" do
            session.update_columns(status: bad_status)
            expect { session.start_reconciling! }.to raise_error(described_class::InvalidTransitionError)
          end
        end
      end

      describe "#start_running! は reconciling / cooling_down 以外から呼ぶと InvalidTransitionError" do
        it "reconciling → running は OK" do
          session.update_columns(status: "reconciling")
          expect { session.start_running! }.not_to raise_error
        end

        it "cooling_down → running も OK(resume 経路)" do
          session.update_columns(status: "cooling_down")
          expect { session.start_running! }.not_to raise_error
        end

        %w[starting running stopping stopped failed_to_start halted].each do |bad_status|
          it "from #{bad_status}: raise" do
            session.update_columns(status: bad_status)
            expect { session.start_running! }.to raise_error(described_class::InvalidTransitionError)
          end
        end
      end

      describe "#start_stopping! は running / cooling_down 以外から呼ぶと InvalidTransitionError" do
        %w[starting reconciling stopping stopped failed_to_start halted].each do |bad_status|
          it "from #{bad_status}: raise" do
            session.update_columns(status: bad_status)
            expect { session.start_stopping! }.to raise_error(described_class::InvalidTransitionError)
          end
        end
      end

      describe "#mark_stopped! は stopping 以外から呼ぶと InvalidTransitionError" do
        %w[starting reconciling running cooling_down stopped failed_to_start halted].each do |bad_status|
          it "from #{bad_status}: raise" do
            session.update_columns(status: bad_status)
            expect { session.mark_stopped! }.to raise_error(described_class::InvalidTransitionError)
          end
        end
      end

      describe "#mark_failed_to_start! は終端状態(stopped/failed_to_start/halted)から呼ぶと InvalidTransitionError" do
        %w[stopped failed_to_start halted].each do |bad_status|
          it "from #{bad_status}: raise(冪等性ガード)" do
            session.update_columns(status: bad_status)
            expect { session.mark_failed_to_start!(reason: "x") }.to raise_error(described_class::InvalidTransitionError)
          end
        end
      end

      describe "#mark_halted! は終端状態(stopped/failed_to_start/halted)から呼ぶと InvalidTransitionError" do
        %w[stopped failed_to_start halted].each do |bad_status|
          it "from #{bad_status}: raise(冪等性ガード)" do
            session.update_columns(status: bad_status)
            expect { session.mark_halted!(reason: "x") }.to raise_error(described_class::InvalidTransitionError)
          end
        end
      end
    end
  end

  describe "FK 不変参照" do
    let(:session) { described_class.create!(base_attributes) }
    let(:other_definition) do
      Strategy::Definition.create!(name: "Other Strat", market_type: "futures", status: "active")
    end

    context "永続化済 Session の strategy_definition_id を変更する場合" do
      it "valid? が false を返し strategy_definition_id にエラーが付与される" do
        session.strategy_definition_id = other_definition.id
        expect(session).not_to be_valid
        expect(session.errors[:strategy_definition_id]).to be_present
      end
    end

    context "永続化済 Session の strategy_revision_id を変更する場合" do
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

      it "valid? が false を返し strategy_revision_id にエラーが付与される" do
        session.strategy_revision_id = other_revision.id
        expect(session).not_to be_valid
        expect(session.errors[:strategy_revision_id]).to be_present
      end
    end

    context "永続化済 Session の risk_policy_id を変更する場合" do
      let(:other_policy) do
        Risk::Policy.create!(
          name: "Other Policy",
          max_drawdown_pct: BigDecimal("10"),
          consecutive_loss_limit: 3,
          max_position_exposure_usdt: BigDecimal("500"),
          max_leverage: 5,
          cooldown_minutes: 15,
          daily_loss_limit_usdt: BigDecimal("250")
        )
      end

      it "valid? が false を返し risk_policy_id にエラーが付与される" do
        session.risk_policy_id = other_policy.id
        expect(session).not_to be_valid
        expect(session.errors[:risk_policy_id]).to be_present
      end
    end
  end
end
