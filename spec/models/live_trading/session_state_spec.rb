require "rails_helper"

RSpec.describe LiveTrading::SessionState, type: :model do
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
        state_data: { "counter" => 0 }
      }
    end

    subject { described_class.new(attributes) }

    context "必須属性が全て揃っている場合" do
      let(:attributes) { base_attributes }

      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end

    context "live_trading_session が nil の場合" do
      let(:attributes) { base_attributes.merge(live_trading_session: nil) }

      it "valid? が false を返し live_trading_session にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:live_trading_session]).to be_present
      end
    end

    context "同じ live_trading_session_id で 2 件目を作成しようとする場合" do
      before { described_class.create!(base_attributes) }

      let(:attributes) { base_attributes.merge(state_data: { "counter" => 1 }) }

      it "1 対 1 制約により valid? が false" do
        expect(subject).not_to be_valid
        expect(subject.errors[:live_trading_session_id]).to be_present
      end
    end
  end

  describe "ActiveRecord 標準 lock_version 楽観ロック(レビュー重要 4 案 A 反映)" do
    let!(:state) do
      described_class.create!(
        live_trading_session: session,
        state_data: { "counter" => 0 }
      )
    end

    context "新規作成時の lock_version は 0" do
      it "0 で初期化される" do
        expect(state.lock_version).to eq(0)
      end
    end

    context "update! で lock_version が自動インクリメントされる場合" do
      it "+1 される" do
        state.update!(state_data: { "counter" => 1 })
        expect(state.lock_version).to eq(1)
      end
    end

    context "古い lock_version で update を試みる場合" do
      it "ActiveRecord::StaleObjectError raise" do
        # 同じレコードを 2 つの instance に取得
        instance_a = described_class.find(state.id)
        instance_b = described_class.find(state.id)

        # A が先に update → lock_version: 0 → 1
        instance_a.update!(state_data: { "counter" => 1 })

        # B は古い lock_version: 0 のまま update → 競合
        expect { instance_b.update!(state_data: { "counter" => 2 }) }
          .to raise_error(ActiveRecord::StaleObjectError)
      end
    end
  end

  describe "#apply_diff!" do
    let!(:state) do
      described_class.create!(
        live_trading_session: session,
        state_data: { "counter" => 0 }
      )
    end

    context "replace_all op が指定された場合" do
      it "state_data が完全置換される + lock_version インクリメント" do
        diff = { "op" => "replace_all", "value" => { "counter" => 5, "active" => true } }
        state.apply_diff!(diff: diff)
        expect(state.state_data).to eq({ "counter" => 5, "active" => true })
        expect(state.lock_version).to eq(1)
      end
    end

    context "未対応 op が指定された場合" do
      it "ArgumentError raise(fail-fast)" do
        diff = { "op" => "unsupported_op", "value" => {} }
        expect { state.apply_diff!(diff: diff) }
          .to raise_error(ArgumentError, /unsupported diff op/)
      end
    end
  end

  describe "#replace_all_state!" do
    let!(:state) do
      described_class.create!(
        live_trading_session: session,
        state_data: { "old_key" => "old_value" }
      )
    end

    context "新しい state を渡した場合" do
      it "state_data が完全置換される + lock_version インクリメント" do
        new_state = { "new_key" => "new_value", "nested" => { "k" => 1 } }
        state.replace_all_state!(new_state: new_state)
        expect(state.state_data).to eq(new_state)
        expect(state.lock_version).to eq(1)
      end
    end
  end

  describe "関連" do
    let(:state) do
      described_class.create!(
        live_trading_session: session,
        state_data: {}
      )
    end

    it "live_trading_session に belongs_to で繋がる" do
      expect(state.live_trading_session).to eq(session)
    end
  end
end
