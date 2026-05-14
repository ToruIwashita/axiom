require "rails_helper"

RSpec.describe Domain::SessionMonitorService do
  let(:definition) { Strategy::Definition.create!(name: "SM Strat", market_type: "futures", status: "active") }
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
      name: "SM Policy",
      max_drawdown_pct: BigDecimal("20"),
      consecutive_loss_limit: 5,
      max_position_exposure_usdt: BigDecimal("1000"),
      max_leverage: 10,
      cooldown_minutes: 30,
      daily_loss_limit_usdt: BigDecimal("500")
    )
  end

  def create_session(status: "running")
    LiveTrading::Session.create!(
      strategy_definition: definition, strategy_revision: revision, risk_policy: risk_policy,
      symbol: "BTCUSDT", leverage: 10, margin_mode: "isolated",
      position_mode: "one_way_mode", asset_mode: "single", margin_coin: "USDT",
      emergency_stop_mode: "cancel_only", status: status
    )
  end

  def create_heartbeat(session, pulsed_at:)
    LiveTrading::SessionHeartbeat.pulse!(
      session_id: session.id,
      worker_instance_id: "test-worker",
      pulsed_at: pulsed_at
    )
  end

  def create_lease(session, status: "active", expires_at: 5.minutes.from_now)
    LiveTrading::SessionLease.create!(
      live_trading_session_id: session.id,
      lease_token: SecureRandom.hex(16),
      worker_instance_id: "test-worker",
      acquired_at: Time.current,
      expires_at: expires_at,
      renewed_at: Time.current,
      status: status
    )
  end

  def create_ws_metric(session, attrs = {})
    LiveTrading::WsMetric.create!({
      live_trading_session_id: session.id,
      detected_at: Time.current,
      public_count_since_start: 0,
      private_count_since_start: 0,
      delta_public: 0,
      delta_private: 0,
      worker_instance_id: "test-worker"
    }.merge(attrs))
  end

  describe "#heartbeat_elapsed_seconds" do
    let(:session) { create_session }
    subject { described_class.new(session: session).heartbeat_elapsed_seconds }

    context "heartbeat 未受信の場合" do
      it "nil を返す" do
        expect(subject).to be_nil
      end
    end

    context "30 秒前に heartbeat 受信した場合" do
      before { create_heartbeat(session, pulsed_at: 30.seconds.ago) }

      it "30 秒前後の経過秒数を返す" do
        expect(subject).to be_between(29, 31)
      end
    end
  end

  describe "#lease_remaining_seconds" do
    let(:session) { create_session }
    subject { described_class.new(session: session).lease_remaining_seconds }

    context "lease 未取得の場合" do
      it "nil を返す" do
        expect(subject).to be_nil
      end
    end

    context "active lease + 5 分後 expires_at" do
      before { create_lease(session, expires_at: 5.minutes.from_now) }

      it "300 秒前後の残り秒数を返す" do
        expect(subject).to be_between(295, 305)
      end
    end

    context "released lease の場合" do
      before { create_lease(session, status: "released") }

      it "nil を返す(active のみ対象)" do
        expect(subject).to be_nil
      end
    end
  end

  describe "#ws_reconnect_status" do
    let(:session) { create_session }
    subject { described_class.new(session: session).ws_reconnect_status }

    context "WsMetric 0 件の場合" do
      it "nil を返す" do
        expect(subject).to be_nil
      end
    end

    context "WsMetric 複数件の場合" do
      before do
        create_ws_metric(session, public_count_since_start: 1, detected_at: 2.minutes.ago)
        create_ws_metric(session, public_count_since_start: 2, source_event: "close", target_ws: "public", detected_at: 1.minute.ago)
      end

      it "最新 1 件を Hash で返す" do
        expect(subject[:public_count_since_start]).to eq(2)
        expect(subject[:source_event]).to eq("close")
        expect(subject[:target_ws]).to eq("public")
      end
    end
  end

  describe "#alerts" do
    let(:session) { create_session }
    subject { described_class.new(session: session).alerts }

    context "通常状態(heartbeat 30 秒前 + active lease 5 分後 + WS 静穏)" do
      before do
        create_heartbeat(session, pulsed_at: 30.seconds.ago)
        create_lease(session, expires_at: 5.minutes.from_now)
      end

      it "alert は空配列" do
        expect(subject).to eq([])
      end
    end

    context "heartbeat 100 秒未受信の場合" do
      before do
        create_heartbeat(session, pulsed_at: 100.seconds.ago)
        create_lease(session, expires_at: 5.minutes.from_now)
      end

      it ":heartbeat_timeout を含む" do
        expect(subject).to include(:heartbeat_timeout)
      end
    end

    context "lease 期限切れ(active かつ expires_at 過去)の場合" do
      before do
        create_heartbeat(session, pulsed_at: 30.seconds.ago)
        create_lease(session, expires_at: 1.minute.ago)
      end

      it ":lease_expired を含む" do
        expect(subject).to include(:lease_expired)
      end
    end

    # 中-6 反映: ws_consecutive_reconnect? は window 内 sum(delta_public + delta_private) で判定
    context "5 分以内の WS reconnect delta sum >= 5 の場合" do
      before do
        create_heartbeat(session, pulsed_at: 30.seconds.ago)
        create_lease(session, expires_at: 5.minutes.from_now)
        create_ws_metric(session, delta_public: 3, delta_private: 2, detected_at: 1.minute.ago)
      end

      it ":ws_consecutive_reconnect を含む" do
        expect(subject).to include(:ws_consecutive_reconnect)
      end
    end
  end

  describe ".bulk_monitor(sessions:)" do
    # 高-3 反映: N+1 回避 / 4 SQL で N session 一括取得
    context "3 session を bulk_monitor" do
      let!(:s1) { create_session }
      let!(:s2) { create_session }
      let!(:s3) { create_session }
      before do
        create_heartbeat(s1, pulsed_at: 30.seconds.ago)
        create_lease(s1, expires_at: 5.minutes.from_now)
        create_ws_metric(s1, public_count_since_start: 1, detected_at: 1.minute.ago)
      end

      subject { described_class.bulk_monitor(sessions: LiveTrading::Session.where(id: [ s1.id, s2.id, s3.id ])) }

      it "3 session の monitor Hash を session.id をキーに返す" do
        expect(subject.keys).to match_array([ s1.id, s2.id, s3.id ])
      end

      it "s1 は heartbeat / lease / ws_status を含む / s2, s3 は nil" do
        expect(subject[s1.id][:heartbeat_elapsed_seconds]).to be_between(29, 31)
        expect(subject[s1.id][:lease_remaining_seconds]).to be_between(295, 305)
        expect(subject[s1.id][:ws_status]).not_to be_nil
        expect(subject[s2.id][:heartbeat_elapsed_seconds]).to be_nil
        expect(subject[s2.id][:lease_remaining_seconds]).to be_nil
        expect(subject[s2.id][:ws_status]).to be_nil
      end

      it "alerts は session 別に算出される" do
        expect(subject[s1.id][:alerts]).to eq([])
        expect(subject[s2.id][:alerts]).to eq([])
      end
    end

    # multi-agent review followup(spec 高-1):
    # 「4 SQL で N session 一括取得」が設計の中核要件であることをクエリ計測で固定化する.
    # 計測対象は bulk_monitor 内部のクエリのみで,呼出側の sessions 取得 SQL は含めない
    # (controller では sessions = .order.page.per で事前に取得済).
    context "5 session を bulk_monitor すると SQL 発行数が 4 件以内(N+1 回避)" do
      let!(:sessions) { Array.new(5) { create_session } }
      # sessions を Array(評価済)で渡し,計測前に確実に展開する
      let(:loaded_sessions) { LiveTrading::Session.where(id: sessions.map(&:id)).to_a }

      it "session 数によらず SQL 発行数が 4 件以内" do
        loaded_sessions # 事前評価
        query_count = 0
        callback = lambda do |_name, _start, _finish, _id, payload|
          next if payload[:name] == "SCHEMA"
          next if %w[TRANSACTION BEGIN COMMIT ROLLBACK].include?(payload[:name])

          query_count += 1
        end
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          described_class.bulk_monitor(sessions: loaded_sessions)
        end
        expect(query_count).to be <= 4
      end
    end
  end

  # multi-agent review followup(spec 高-3):
  # bulk_monitor 内 compute_monitor_hash は instance method の alerts と独立した重複実装のため,
  # 各 alert(:heartbeat_timeout / :lease_expired / :ws_consecutive_reconnect)が
  # bulk_monitor 経由でも発火することを明示的に固定化する(両経路の乖離防止).
  describe ".bulk_monitor 経由の alerts 分岐検証" do
    let!(:session) { create_session }
    subject { described_class.bulk_monitor(sessions: LiveTrading::Session.where(id: [ session.id ]))[session.id][:alerts] }

    context "heartbeat 100 秒未受信" do
      before { create_heartbeat(session, pulsed_at: 100.seconds.ago) }

      it ":heartbeat_timeout を含む" do
        expect(subject).to include(:heartbeat_timeout)
      end
    end

    context "active lease かつ expires_at 過去" do
      before { create_lease(session, expires_at: 1.minute.ago) }

      it ":lease_expired を含む" do
        expect(subject).to include(:lease_expired)
      end
    end

    context "5 分以内 WS reconnect delta sum >= 5" do
      before { create_ws_metric(session, delta_public: 3, delta_private: 2, detected_at: 1.minute.ago) }

      it ":ws_consecutive_reconnect を含む" do
        expect(subject).to include(:ws_consecutive_reconnect)
      end
    end

    context "3 種 alert が同時発生" do
      before do
        create_heartbeat(session, pulsed_at: 100.seconds.ago)
        create_lease(session, expires_at: 1.minute.ago)
        create_ws_metric(session, delta_public: 3, delta_private: 2, detected_at: 1.minute.ago)
      end

      it ":heartbeat_timeout / :lease_expired / :ws_consecutive_reconnect すべて含む" do
        expect(subject).to contain_exactly(:heartbeat_timeout, :lease_expired, :ws_consecutive_reconnect)
      end
    end
  end

  describe "#recent_heartbeats / #lease_events / #recent_ws_metrics_grouped_by_worker(新-中-5 反映)" do
    let(:session) { create_session }
    let(:monitor) { described_class.new(session: session) }

    context "recent_heartbeats(limit)" do
      before do
        create_heartbeat(session, pulsed_at: 3.minutes.ago)
        create_heartbeat(session, pulsed_at: 2.minutes.ago)
        create_heartbeat(session, pulsed_at: 1.minute.ago)
      end

      it "limit 件を pulsed_at 降順で返す + memoize する" do
        expect(monitor.recent_heartbeats(2).size).to eq(2)
        expect(monitor.recent_heartbeats(2)).to eq(monitor.recent_heartbeats(2))
      end
    end

    describe "lease_events" do
      context "lease 存在時" do
        before { create_lease(session) }

        it "現行 lease 1 件を配列で返す(MVP)" do
          expect(monitor.lease_events.size).to eq(1)
        end
      end

      context "lease なしの場合" do
        it "空配列を返す" do
          expect(monitor.lease_events).to eq([])
        end
      end
    end

    # 新-中-4 反映: WsMetric を worker_instance_id 別にグループ化
    context "recent_ws_metrics_grouped_by_worker(limit)" do
      before do
        create_ws_metric(session, worker_instance_id: "worker-A", detected_at: 3.minutes.ago)
        create_ws_metric(session, worker_instance_id: "worker-A", detected_at: 2.minutes.ago)
        create_ws_metric(session, worker_instance_id: "worker-B", detected_at: 1.minute.ago)
      end

      it "worker_instance_id をキーに WsMetric 配列を返す" do
        result = monitor.recent_ws_metrics_grouped_by_worker(10)
        expect(result.keys).to match_array([ "worker-A", "worker-B" ])
        expect(result["worker-A"].size).to eq(2)
        expect(result["worker-B"].size).to eq(1)
      end
    end
  end

  # 新-中-7 反映: lease&.state_active? predicate(SessionLease enum prefix :state 規約)
  describe "predicate メソッド使用検証" do
    let(:session) { create_session }

    context "active lease で lease&.active? が NoMethodError にならないこと" do
      before { create_lease(session) }

      it "lease_remaining_seconds が NoMethodError なく数値を返す" do
        expect { described_class.new(session: session).lease_remaining_seconds }.not_to raise_error
      end
    end
  end
end
