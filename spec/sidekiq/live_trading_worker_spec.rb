require "rails_helper"

RSpec.describe LiveTradingWorker do
  let(:process_manager) { instance_double(Domain::LiveTradingProcessManager) }
  let(:lease) { instance_double(LiveTrading::SessionLease) }
  let(:logger) { instance_double(Logger, warn: nil, info: nil, error: nil, debug: nil) }
  let(:clock_sync) { instance_double(Infrastructure::BitgetClockSync) }
  let(:market_endpoint) { instance_double(Infrastructure::BitgetMarketEndpoint) }
  let(:position_endpoint) { instance_double(Infrastructure::BitgetPositionEndpoint) }
  let(:order_endpoint_di) { instance_double(Infrastructure::BitgetOrderEndpoint) }
  let(:contract_metadata_response) do
    {
      symbol: "BTCUSDT", price_place: 1, price_end_step: 1, tick_size: BigDecimal("0.1"),
      volume_place: 3, size_multiplier: BigDecimal("0.001"), min_trade_num: BigDecimal("0.001"),
      base_coin: "BTC", quote_coin: "USDT"
    }
  end
  let(:warmup_candles_response) do
    [
      { ts: 1_234_567_890_123, open: "50000", high: "50500", low: "49500", close: "50200",
        base_volume: "100", quote_volume: "5020000", usdt_volume: "5020000" }
    ]
  end
  let(:public_ws) { instance_double(Infrastructure::BitgetPublicWsClient) }
  let(:private_ws) { instance_double(Infrastructure::BitgetPrivateWsClient) }
  let(:public_ws_factory) { -> { public_ws } }
  let(:private_ws_factory) { -> { private_ws } }
  let(:worker) do
    described_class.new(
      process_manager: process_manager,
      clock_sync: clock_sync,
      market_endpoint: market_endpoint,
      position_endpoint: position_endpoint,
      public_ws_factory: public_ws_factory,
      private_ws_factory: private_ws_factory,
      order_endpoint: order_endpoint_di,
      main_loop_poll_interval: 0, # spec ではループを sleep させない
      logger: logger
    )
  end

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
    allow(clock_sync).to receive(:sync!).and_return(0.123)
    allow(market_endpoint).to receive(:contract_metadata).and_return(contract_metadata_response)
    allow(market_endpoint).to receive(:history_futures_candles).and_return(warmup_candles_response)
    allow(position_endpoint).to receive(:set_margin_mode)
    allow(position_endpoint).to receive(:set_position_mode)
    allow(position_endpoint).to receive(:set_asset_mode)
    allow(position_endpoint).to receive(:set_leverage)
    allow(public_ws).to receive(:connect)
    allow(public_ws).to receive(:subscribe)
    allow(public_ws).to receive(:disconnect)
    allow(public_ws).to receive(:connected?).and_return(true)
    allow(public_ws).to receive(:reconnect_count).and_return(0)
    allow(private_ws).to receive(:connect)
    allow(private_ws).to receive(:subscribe)
    allow(private_ws).to receive(:disconnect)
    allow(private_ws).to receive(:connected?).and_return(true)
    allow(private_ws).to receive(:reconnect_count).and_return(0)
    # main loop は default で 1 iteration で抜ける(spec hang 回避)
    allow(process_manager).to receive(:signal_kill_switch?).and_return(true)
    # heartbeat / lease renew(3.3-12)default stub
    allow(process_manager).to receive(:pulse_heartbeat!)
    allow(process_manager).to receive(:renew_lease!)
    # reconciliation 6 件 REST(3.3-11): default で空 data 返却
    allow(order_endpoint_di).to receive(:orders_pending).and_return("data" => [])
    allow(order_endpoint_di).to receive(:orders_plan_pending).and_return("data" => [])
    allow(order_endpoint_di).to receive(:orders_plan_history).and_return("data" => [])
    allow(position_endpoint).to receive(:position_all).and_return("data" => [])
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
    context "step 1-13 全成功(bootstrap 完走)" do
      it "process_manager.acquire_lease! を session + worker_instance_id で呼ぶ" do
        worker.perform(session.id)

        expect(process_manager).to have_received(:acquire_lease!).with(
          session: an_object_having_attributes(id: session.id),
          worker_instance_id: a_kind_of(String)
        )
      end

      it "session が starting → reconciling → running まで遷移し started_at を記録する" do
        worker.perform(session.id)
        expect(session.reload.state_running?).to be true
        expect(session.started_at).to be_present
      end

      it "step 12: LiveTrading::SessionState を空 state_data で作成する" do
        expect { worker.perform(session.id) }.to change { LiveTrading::SessionState.count }.by(1)
        expect(LiveTrading::SessionState.last.state_data).to eq({})
        expect(LiveTrading::SessionState.last.live_trading_session_id).to eq(session.id)
      end

      it "step 12: 既存 SessionState がある場合(再起動)は新規作成しない" do
        LiveTrading::SessionState.create!(live_trading_session_id: session.id, state_data: { "ema" => 50_100 })

        expect { worker.perform(session.id) }.not_to change { LiveTrading::SessionState.count }
        expect(LiveTrading::SessionState.find_by(live_trading_session_id: session.id).state_data)
          .to eq({ "ema" => 50_100 })
      end

      it "step 5: clock_sync.sync! を呼ぶ" do
        worker.perform(session.id)
        expect(clock_sync).to have_received(:sync!)
      end

      it "step 6: market_endpoint.contract_metadata を symbol で呼ぶ" do
        worker.perform(session.id)
        expect(market_endpoint).to have_received(:contract_metadata).with(symbol: "BTCUSDT")
      end

      it "step 7: position_endpoint で margin/position/asset/leverage を session 値で適用する" do
        worker.perform(session.id)

        expect(position_endpoint).to have_received(:set_margin_mode).with(
          symbol: "BTCUSDT", margin_coin: "USDT", margin_mode: "isolated"
        )
        expect(position_endpoint).to have_received(:set_position_mode).with(position_mode: "one_way_mode")
        expect(position_endpoint).to have_received(:set_asset_mode).with(asset_mode: "single")
        expect(position_endpoint).to have_received(:set_leverage).with(
          symbol: "BTCUSDT", margin_coin: "USDT", leverage: 10
        )
      end

      it "step 8: market_endpoint.history_futures_candles を warmup default(1m / 200)で呼ぶ" do
        worker.perform(session.id)
        expect(market_endpoint).to have_received(:history_futures_candles).with(
          symbol: "BTCUSDT", granularity: "1m", limit: 200
        )
      end

      it "step 9: public_ws.connect + 3 subscribe(ticker / candle1m / books5)を呼ぶ" do
        worker.perform(session.id)

        expect(public_ws).to have_received(:connect)
        expect(public_ws).to have_received(:subscribe).exactly(3).times
        # 各 subscription の channel/inst_type/inst_id 検証
        expect(public_ws).to have_received(:subscribe).with(
          an_object_having_attributes(channel: "ticker", inst_type: "USDT-FUTURES", inst_id: "BTCUSDT")
        )
        expect(public_ws).to have_received(:subscribe).with(
          an_object_having_attributes(channel: "candle1m", inst_type: "USDT-FUTURES", inst_id: "BTCUSDT")
        )
        expect(public_ws).to have_received(:subscribe).with(
          an_object_having_attributes(channel: "books5", inst_type: "USDT-FUTURES", inst_id: "BTCUSDT")
        )
      end

      it "step 10: private_ws subscribe (6 channels) → connect の順で呼ぶ" do
        worker.perform(session.id)

        expect(private_ws).to have_received(:subscribe).exactly(6).times
        %w[orders orders-algo fill positions positions-history account].each do |channel|
          expect(private_ws).to have_received(:subscribe).with(
            an_object_having_attributes(channel: channel, inst_type: "USDT-FUTURES", inst_id: "BTCUSDT")
          )
        end
        expect(private_ws).to have_received(:connect)
      end
    end

    # step 5-8 の失敗パス: lease 取得済み → cleanup_on_failure で release! + mark_failed_to_start!
    shared_examples "step 5+ failure cleanup" do |error_class:, error_pattern:|
      it "#{error_class} を raise + failed_to_start 遷移" do
        expect { worker.perform(session.id) }.to raise_error(error_class, error_pattern)
        expect(session.reload.state_failed_to_start?).to be true
      end

      it "lease.release! を呼ぶ(step 5+ で lease 取得済みのため)" do
        expect { worker.perform(session.id) }.to raise_error(error_class)
        expect(lease).to have_received(:release!)
      end
    end

    context "step 5 失敗(clock_sync.sync! が nil 返却)" do
      before do
        allow(clock_sync).to receive(:sync!).and_return(nil)
      end

      include_examples "step 5+ failure cleanup",
                       error_class: StandardError,
                       error_pattern: /clock sync failed/
    end

    context "step 6 失敗(market_endpoint.contract_metadata raise)" do
      before do
        allow(market_endpoint).to receive(:contract_metadata)
          .and_raise(ArgumentError, "symbol not found (symbol=BTCUSDT)")
      end

      include_examples "step 5+ failure cleanup",
                       error_class: ArgumentError,
                       error_pattern: /symbol not found/
    end

    context "step 7 失敗(position_endpoint.set_margin_mode raise)" do
      before do
        allow(position_endpoint).to receive(:set_margin_mode)
          .and_raise(StandardError, "set_margin_mode API error")
      end

      include_examples "step 5+ failure cleanup",
                       error_class: StandardError,
                       error_pattern: /set_margin_mode API error/
    end

    context "step 8 失敗(market_endpoint.history_futures_candles raise)" do
      before do
        allow(market_endpoint).to receive(:history_futures_candles)
          .and_raise(StandardError, "history candles API error")
      end

      include_examples "step 5+ failure cleanup",
                       error_class: StandardError,
                       error_pattern: /history candles API error/
    end

    context "step 9 失敗(public_ws.connect ConnectionError)" do
      before do
        allow(public_ws).to receive(:connect)
          .and_raise(Infrastructure::BitgetPublicWsClient::ConnectionError, "WS open timeout")
        allow(public_ws).to receive(:connected?).and_return(false) # connect 失敗のため false
      end

      it "ConnectionError を raise + failed_to_start 遷移" do
        expect { worker.perform(session.id) }.to raise_error(Infrastructure::BitgetPublicWsClient::ConnectionError)
        expect(session.reload.state_failed_to_start?).to be true
      end

      it "lease.release! を呼ぶ(step 5+ で lease 取得済み)" do
        expect { worker.perform(session.id) }.to raise_error(Infrastructure::BitgetPublicWsClient::ConnectionError)
        expect(lease).to have_received(:release!)
      end

      it "public_ws.disconnect は呼ばない(connected? が false のため)" do
        expect { worker.perform(session.id) }.to raise_error(Infrastructure::BitgetPublicWsClient::ConnectionError)
        expect(public_ws).not_to have_received(:disconnect)
      end
    end

    context "step 10 失敗(private_ws.connect LoginFailedError 軽微 obs 2)" do
      before do
        allow(private_ws).to receive(:connect)
          .and_raise(Infrastructure::BitgetPrivateWsClient::LoginFailedError, "login signature rejected")
      end

      it "LoginFailedError を raise + failed_to_start 遷移" do
        expect { worker.perform(session.id) }
          .to raise_error(Infrastructure::BitgetPrivateWsClient::LoginFailedError, /login signature rejected/)
        expect(session.reload.state_failed_to_start?).to be true
      end

      it "lease.release! を呼ぶ" do
        expect { worker.perform(session.id) }.to raise_error(Infrastructure::BitgetPrivateWsClient::LoginFailedError)
        expect(lease).to have_received(:release!)
      end

      it "public_ws.disconnect を呼ぶ(step 9 で接続済みのため)" do
        expect { worker.perform(session.id) }.to raise_error(Infrastructure::BitgetPrivateWsClient::LoginFailedError)
        expect(public_ws).to have_received(:disconnect)
      end

      it "private_ws.disconnect は connected? が false なら呼ばない" do
        allow(private_ws).to receive(:connected?).and_return(false)
        expect { worker.perform(session.id) }.to raise_error(Infrastructure::BitgetPrivateWsClient::LoginFailedError)
        expect(private_ws).not_to have_received(:disconnect)
      end
    end

    context "step 10 失敗(private_ws SubscribeFailedError 軽微 obs 2)" do
      before do
        allow(private_ws).to receive(:connect)
          .and_raise(Infrastructure::BitgetPrivateWsClient::SubscribeFailedError, "subscribe rejected")
      end

      it "SubscribeFailedError を raise + failed_to_start 遷移 + public_ws.disconnect" do
        expect { worker.perform(session.id) }
          .to raise_error(Infrastructure::BitgetPrivateWsClient::SubscribeFailedError, /subscribe rejected/)
        expect(session.reload.state_failed_to_start?).to be true
        expect(public_ws).to have_received(:disconnect)
        expect(lease).to have_received(:release!)
      end
    end

    context "step 11 失敗(start_reconciling! が InvalidTransitionError)" do
      before do
        # session が starting でないと start_reconciling! 失敗する状況を作るため
        # 後段で context 強制. ここでは update_column で starting 以外に更新.
        # ただし step 1-10 は session 操作で starting を前提に進むので,
        # step 11 失敗は session.start_reconciling! が raise する case を直接 stub する.
        allow_any_instance_of(LiveTrading::Session).to receive(:start_reconciling!)
          .and_raise(LiveTrading::Session::InvalidTransitionError, "transition rejected")
      end

      it "InvalidTransitionError を raise + failed_to_start 遷移 + lease.release! + WS disconnect" do
        expect { worker.perform(session.id) }
          .to raise_error(LiveTrading::Session::InvalidTransitionError, /transition rejected/)
        expect(session.reload.state_failed_to_start?).to be true
        expect(public_ws).to have_received(:disconnect)
        expect(private_ws).to have_received(:disconnect)
        expect(lease).to have_received(:release!)
      end
    end

    context "step 12 失敗(SessionState 作成 DB エラー)" do
      before do
        allow(LiveTrading::SessionState).to receive(:find_or_create_by!)
          .and_raise(ActiveRecord::RecordInvalid.new(LiveTrading::SessionState.new))
      end

      it "RecordInvalid を raise + failed_to_start 遷移 + lease.release! + WS disconnect" do
        expect { worker.perform(session.id) }.to raise_error(ActiveRecord::RecordInvalid)
        expect(session.reload.state_failed_to_start?).to be true
        expect(public_ws).to have_received(:disconnect)
        expect(private_ws).to have_received(:disconnect)
        expect(lease).to have_received(:release!)
      end
    end

    context "step 13 失敗(start_running! が InvalidTransitionError)" do
      before do
        allow_any_instance_of(LiveTrading::Session).to receive(:start_running!)
          .and_raise(LiveTrading::Session::InvalidTransitionError, "running transition rejected")
      end

      it "InvalidTransitionError を raise + failed_to_start 遷移 + lease.release! + WS disconnect" do
        expect { worker.perform(session.id) }
          .to raise_error(LiveTrading::Session::InvalidTransitionError, /running transition rejected/)
        expect(session.reload.state_failed_to_start?).to be true
        expect(public_ws).to have_received(:disconnect)
        expect(private_ws).to have_received(:disconnect)
        expect(lease).to have_received(:release!)
      end
    end

    # 軽微 obs 1 拡張: WS.disconnect 例外連鎖失敗対策
    context "cleanup_on_failure 中に public_ws.disconnect が raise した場合" do
      before do
        allow(private_ws).to receive(:connect)
          .and_raise(Infrastructure::BitgetPrivateWsClient::LoginFailedError, "login error")
        allow(public_ws).to receive(:disconnect).and_raise(StandardError, "disconnect timeout")
      end

      it "logger.warn 落とし + lease.release! + mark_failed_to_start! が継続実行される" do
        expect { worker.perform(session.id) }.to raise_error(Infrastructure::BitgetPrivateWsClient::LoginFailedError)

        expect(logger).to have_received(:warn).with(
          /public_ws.disconnect failed during cleanup_on_failure.*disconnect timeout/
        )
        expect(lease).to have_received(:release!)
        expect(session.reload.state_failed_to_start?).to be true
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

    # 重要 obs 1 反映: cleanup_on_failure 内 reload.terminal? race window 閉塞
    context "bootstrap 中に他プロセスが session.status を halted に直接変更(race condition)" do
      before do
        allow(process_manager).to receive(:acquire_lease!) do
          # bootstrap 中の external state change を模擬
          LiveTrading::Session.where(id: session.id).update_all(status: "halted")
          raise StandardError, "external state change"
        end
      end

      it "reload 後 terminal 検出で mark_failed_to_start! を呼ばない(halted 履歴維持)" do
        expect { worker.perform(session.id) }.to raise_error(StandardError, "external state change")
        expect(session.reload.state_halted?).to be true
      end

      it "lease.release! は呼ばれない(reload.terminal? で early return)" do
        expect { worker.perform(session.id) }.to raise_error(StandardError)
        expect(lease).not_to have_received(:release!)
      end
    end

    # 軽微 obs 1 反映: release! 例外連鎖失敗対策
    context "step 5+ 相当の cleanup で lease.release! が raise した場合(連鎖失敗対策)" do
      let(:release_error_class) { Class.new(StandardError) }

      before do
        # step 4 直後 (lease 取得済み) に外部要因で StandardError raise を発生させる構造を模擬:
        # acquire_lease! は成功させ, 直後の load_revision_with_consistency 後の Risk::Policy.find で
        # 例外を raise して step 5+ 相当の cleanup 経路に持ち込む.
        # 具体: lease は取得済みかつ release! が raise する状況を直接構築.
        allow(lease).to receive(:state_released?).and_return(false)
        allow(lease).to receive(:release!).and_raise(release_error_class, "release timeout")

        # acquire_lease! 成功後に bootstrap 内で意図的に raise させるため,
        # session.start_running! 等が無い 3.3-9a スコープでは process_manager.acquire_lease! 直後の
        # 「step 5 相当の例外」を模擬. acquire_lease! を成功させた直後に raise する形は難しいので,
        # bootstrap 後段の架空 step 失敗として acquire_lease! 自体は成功 + その後 LiveTrading::Session#reload
        # を stub して raise させることで step 5+ 相当を模擬する代替も難しい.
        # 代替として: cleanup_on_failure を直接テストする(unit-level).
      end

      it "lease.release! 例外を logger.warn に落とし mark_failed_to_start! を実行する" do
        # cleanup_on_failure を直接呼び出して挙動検証
        # (3.3-9a 起源のスコープ. 3.3-9c 以降は public_ws/private_ws も渡す signature)
        worker.send(:cleanup_on_failure,
                    session: session,
                    lease: lease,
                    public_ws: nil,
                    private_ws: nil,
                    error: StandardError.new("step 5+ failure"))

        expect(logger).to have_received(:warn).with(
          /lease.release! failed during cleanup_on_failure.*release timeout/
        )
        expect(session.reload.state_failed_to_start?).to be true
      end
    end

    describe "メインループ終了パス" do
      context "kill-switch 検出 + session が stopping 状態" do
        before do
          # bootstrap で running になった後, 即時 stopping → kill-switch true 返却
          allow(process_manager).to receive(:signal_kill_switch?) do
            session.update_column(:status, "stopping") if session.persisted? && !session.reload.state_stopping?
            true
          end
        end

        it "session が stopping → stopped に遷移する" do
          worker.perform(session.id)
          expect(session.reload.state_stopped?).to be true
        end

        it "WS disconnect + lease.release! が呼ばれる" do
          worker.perform(session.id)
          expect(public_ws).to have_received(:disconnect)
          expect(private_ws).to have_received(:disconnect)
          expect(lease).to have_received(:release!)
        end
      end

      context "kill-switch 検出だが session が running のまま(防御)" do
        # default before で signal_kill_switch? = true / session は bootstrap で running のまま
        it "session の status は running のままで mark_stopped! は呼ばれない" do
          worker.perform(session.id)
          expect(session.reload.state_running?).to be true
        end

        it "WS disconnect + lease.release! は呼ばれる(リソース解放は実行)" do
          worker.perform(session.id)
          expect(public_ws).to have_received(:disconnect)
          expect(private_ws).to have_received(:disconnect)
          expect(lease).to have_received(:release!)
        end
      end

      context "他プロセスが session を halted に直接変更(terminal 検出)" do
        before do
          # main loop 1 iteration 目の signal_kill_switch? 呼出時に session を halted に外部更新
          first_call = true
          allow(process_manager).to receive(:signal_kill_switch?) do |**_|
            if first_call
              first_call = false
              LiveTrading::Session.where(id: session.id).update_all(status: "halted")
            end
            false
          end
        end

        it "exit_reason: terminal で main loop を抜け session を halted のまま維持" do
          worker.perform(session.id)
          expect(session.reload.state_halted?).to be true
        end

        it "WS disconnect + lease.release! は呼ばれる" do
          worker.perform(session.id)
          expect(public_ws).to have_received(:disconnect)
          expect(lease).to have_received(:release!)
        end
      end

      context "WS 切断検知(public_ws.connected? が false)" do
        before do
          allow(process_manager).to receive(:signal_kill_switch?).and_return(false)
          allow(public_ws).to receive(:connected?).and_return(false)
        end

        it "session を mark_halted!(reason: ws_disconnected)に遷移させる" do
          worker.perform(session.id)
          expect(session.reload.state_halted?).to be true
          expect(session.failure_reason).to include("ws_disconnected")
        end

        it "failure_reason に public_ws / private_ws の状態を含める(軽微 obs 3)" do
          worker.perform(session.id)
          expect(session.reload.failure_reason).to match(/public_ws=false/)
          expect(session.reload.failure_reason).to match(/private_ws=true/)
        end

        it "public_ws.disconnect は呼ばれない(connected? false でスキップ) + lease.release! は呼ばれる" do
          worker.perform(session.id)
          expect(public_ws).not_to have_received(:disconnect)
          expect(lease).to have_received(:release!)
        end
      end

      # 軽微 obs 5 反映: private_ws 単独切断シナリオの独立検証
      context "WS 切断検知(private_ws.connected? が false / public_ws は true)" do
        before do
          allow(process_manager).to receive(:signal_kill_switch?).and_return(false)
          allow(public_ws).to receive(:connected?).and_return(true)
          allow(private_ws).to receive(:connected?).and_return(false)
        end

        it "ws_healthy? の && 短絡評価で ws_disconnected と判定される" do
          worker.perform(session.id)
          expect(session.reload.state_halted?).to be true
        end

        it "failure_reason に private_ws=false が含まれる" do
          worker.perform(session.id)
          expect(session.reload.failure_reason).to match(/private_ws=false/)
          expect(session.reload.failure_reason).to match(/public_ws=true/)
        end

        it "public_ws.disconnect は呼ばれる(connected? true) + private_ws.disconnect はスキップ" do
          worker.perform(session.id)
          expect(public_ws).to have_received(:disconnect)
          expect(private_ws).not_to have_received(:disconnect)
        end
      end

      context "finalize_main_loop で lease.release! が raise した場合(連鎖失敗対策)" do
        before do
          allow(lease).to receive(:release!).and_raise(StandardError, "release timeout in finalize")
        end

        it "logger.warn 落とし + 例外を再 raise しない" do
          expect { worker.perform(session.id) }.not_to raise_error

          expect(logger).to have_received(:warn).with(
            /lease.release! failed during finalize_main_loop.*release timeout in finalize/
          )
        end
      end
    end

    describe "Public WS callback(3.3-10b)" do
      let(:candle1m_sub) do
        Infrastructure::BitgetPublicWsSubscription.new(
          channel: "candle1m", inst_type: "USDT-FUTURES", inst_id: "BTCUSDT"
        )
      end
      let(:ticker_sub) do
        Infrastructure::BitgetPublicWsSubscription.new(
          channel: "ticker", inst_type: "USDT-FUTURES", inst_id: "BTCUSDT"
        )
      end

      before do
        # bootstrap で session を作成しておくが main loop 内処理は不要
        worker.send(:instance_variable_set, :@session, session)
        worker.send(:instance_variable_set, :@last_candle_row, nil)
        # run_in_db_thread を同期化(spec hang 回避)
        allow(worker).to receive(:run_in_db_thread) do |_label, &block|
          block.call
        end
      end

      describe "#handle_public_ws_message" do
        let(:update_result) { double("Push", snapshot?: false) }
        let(:snapshot_result) { double("Push", snapshot?: true) }

        context "channel=candle1m の場合" do
          it "handle_candle_message に data + snapshot フラグを引数として dispatch する" do
            expect(worker).to receive(:handle_candle_message).with(an_instance_of(Array), snapshot: false)
            worker.send(:handle_public_ws_message, candle1m_sub, [], update_result)
          end
        end

        context "channel=ticker の場合(MVP では未処理)" do
          it "handle_candle_message を呼ばない" do
            expect(worker).not_to receive(:handle_candle_message)
            worker.send(:handle_public_ws_message, ticker_sub, [], update_result)
          end
        end

        context "callback 内で例外が raise した場合" do
          before do
            allow(worker).to receive(:handle_candle_message).and_raise(StandardError, "callback failure")
          end

          it "logger.warn 落とし + WS thread を止めない(再 raise しない)" do
            expect do
              worker.send(:handle_public_ws_message, candle1m_sub, [], update_result)
            end.not_to raise_error

            expect(logger).to have_received(:warn).with(
              /handle_public_ws_message failed in channel=candle1m.*callback failure/
            )
          end
        end
      end

      describe "#handle_candle_message + #detect_confirmed_candle(確定判定)" do
        let(:row1) { [ 1_700_000_000_000, "50000", "50100", "49900", "50050", "10", "500000", "500000" ] }
        let(:row2) { [ 1_700_000_060_000, "50050", "50200", "50000", "50150", "12", "601800", "601800" ] }

        context "初回 candle1m 受信 update(@last_candle_row が nil)" do
          it "確定 candle なし(spawn を呼ばない)" do
            expect(worker).not_to receive(:spawn_runner_child_for_tick)
            worker.send(:handle_candle_message, [ row1 ], snapshot: false)
          end

          it "@last_candle_row が更新される" do
            worker.send(:handle_candle_message, [ row1 ], snapshot: false)
            expect(worker.instance_variable_get(:@last_candle_row)).to eq(row1)
          end
        end

        context "同一 ts の candle1m 再受信(更新中)" do
          before do
            worker.send(:handle_candle_message, [ row1 ], snapshot: false)
          end

          it "確定 candle なし(spawn を呼ばない)" do
            updated_row1 = [ row1[0], "50000", "50500", "49800", "50300", "20", "1000000", "1000000" ]
            expect(worker).not_to receive(:spawn_runner_child_for_tick)
            worker.send(:handle_candle_message, [ updated_row1 ], snapshot: false)
          end
        end

        context "ts が進んだ candle1m 受信(前 candle 確定)" do
          before do
            worker.send(:handle_candle_message, [ row1 ], snapshot: false)
          end

          it "前 candle(row1)が確定 payload として spawn される" do
            expect(worker).to receive(:spawn_runner_child_for_tick).with(
              a_hash_including(
                "ts" => row1[0],
                "open" => "50000",
                "high" => "50100",
                "low" => "49900",
                "close" => "50050"
              )
            )
            worker.send(:handle_candle_message, [ row2 ], snapshot: false)
          end
        end

        # R-1 #2 反映: snapshot 時に過去履歴 row 全件確定誤検出を防ぐ
        context "candle1m snapshot 受信(接続直後の過去履歴一括 push)" do
          let(:snapshot_rows) { [ row1, row2 ] }

          it "spawn を 1 度も呼ばない(過去履歴は warmup_candles で別途取得済)" do
            expect(worker).not_to receive(:spawn_runner_child_for_tick)
            worker.send(:handle_candle_message, snapshot_rows, snapshot: true)
          end

          it "@last_candle_row が末尾 row(最新)で初期化される" do
            worker.send(:handle_candle_message, snapshot_rows, snapshot: true)
            expect(worker.instance_variable_get(:@last_candle_row)).to eq(row2)
          end
        end

        context "data が Array でない場合" do
          it "nil は no-op" do
            expect(worker).not_to receive(:spawn_runner_child_for_tick)
            worker.send(:handle_candle_message, nil, snapshot: false)
          end

          it "Hash は no-op" do
            expect(worker).not_to receive(:spawn_runner_child_for_tick)
            worker.send(:handle_candle_message, { "data" => "not-array" }, snapshot: false)
          end
        end
      end

      describe "#spawn_runner_child_for_tick" do
        let(:candle_payload) { { "ts" => 1_700_000_000_000, "close" => "50050" } }

        it "run_in_db_thread で別 thread + AR pool を確保した中で session.reload + run_runner_child_for_tick を呼ぶ" do
          expect(worker).to receive(:run_runner_child_for_tick).with(
            an_object_having_attributes(id: session.id),
            candle_payload
          )

          worker.send(:spawn_runner_child_for_tick, candle_payload)

          expect(worker).to have_received(:run_in_db_thread).with("runner_child_for_tick")
        end
      end
    end

    describe "Private WS callback(3.3-10c)" do
      # Result::Push は private constant のため duck typing で double 化
      let(:result_double) { double("Push", algo_anomaly?: false) }

      before do
        worker.send(:instance_variable_set, :@session, session)
        # run_in_db_thread を同期化(spec hang 回避)
        allow(worker).to receive(:run_in_db_thread) do |_label, &block|
          block.call
        end
      end

      describe "#handle_private_ws_message dispatch" do
        %w[orders orders-algo fill positions positions-history account].each do |channel|
          context "channel=#{channel}" do
            let(:sub) do
              Infrastructure::BitgetPrivateWsSubscription.new(
                channel: channel, inst_type: "USDT-FUTURES", inst_id: "BTCUSDT"
              )
            end
            let(:expected_method) do
              case channel
              when "orders" then :handle_orders_message
              when "orders-algo" then :handle_orders_algo_message
              when "fill" then :handle_fill_message
              when "positions" then :handle_positions_message
              when "positions-history" then :handle_positions_history_message
              when "account" then :handle_account_message
              end
            end

            it "対応する handler に dispatch される" do
              if channel == "orders-algo"
                expect(worker).to receive(expected_method).with([], result_double)
              else
                expect(worker).to receive(expected_method).with([])
              end
              worker.send(:handle_private_ws_message, sub, [], result_double)
            end
          end
        end

        context "callback 内で例外が raise した場合" do
          let(:sub) do
            Infrastructure::BitgetPrivateWsSubscription.new(
              channel: "orders", inst_type: "USDT-FUTURES", inst_id: "BTCUSDT"
            )
          end

          before do
            allow(worker).to receive(:handle_orders_message).and_raise(StandardError, "callback failure")
          end

          it "logger.warn 落とし + WS thread を止めない" do
            expect do
              worker.send(:handle_private_ws_message, sub, [], result_double)
            end.not_to raise_error

            expect(logger).to have_received(:warn).with(
              /handle_private_ws_message failed in channel=orders.*callback failure/
            )
          end
        end
      end

      describe "#handle_orders_message" do
        it "run_in_db_thread + transaction で wrap され処理が呼ばれる" do
          expect(LiveTrading::Session).to receive(:transaction).and_yield
          worker.send(:handle_orders_message, [ { "client_oid" => "abc" } ])
          expect(worker).to have_received(:run_in_db_thread).with("orders_update")
        end
      end

      describe "#handle_orders_algo_message" do
        context "algo_anomaly? = true(設計書 05_§3.6 異常状態)" do
          let(:anomaly_result) { double("Push", algo_anomaly?: true) }

          it "logger.warn でアラート出力" do
            allow(LiveTrading::Session).to receive(:transaction).and_yield
            worker.send(:handle_orders_algo_message, [], anomaly_result)
            expect(logger).to have_received(:warn).with(/orders-algo anomaly detected/)
          end
        end

        context "algo_anomaly? = false(正常状態)" do
          it "アラートなしで run_in_db_thread + transaction wrap" do
            expect(LiveTrading::Session).to receive(:transaction).and_yield
            worker.send(:handle_orders_algo_message, [], result_double)
            expect(logger).not_to have_received(:warn)
            expect(worker).to have_received(:run_in_db_thread).with("orders_algo_update")
          end
        end
      end

      describe "#handle_fill_message" do
        it "run_in_db_thread + transaction で wrap される(ラベル: fill_create)" do
          expect(LiveTrading::Session).to receive(:transaction).and_yield
          worker.send(:handle_fill_message, [])
          expect(worker).to have_received(:run_in_db_thread).with("fill_create")
        end
      end

      describe "#handle_positions_message / #handle_positions_history_message" do
        it "positions_update / positions_history ラベルで run_in_db_thread + transaction" do
          allow(LiveTrading::Session).to receive(:transaction).and_yield
          worker.send(:handle_positions_message, [])
          worker.send(:handle_positions_history_message, [])
          expect(worker).to have_received(:run_in_db_thread).with("positions_update")
          expect(worker).to have_received(:run_in_db_thread).with("positions_history")
        end
      end

      describe "#handle_account_message" do
        it "account_update ラベルで run_in_db_thread(現状 transaction なし skeleton)" do
          worker.send(:handle_account_message, [])
          expect(worker).to have_received(:run_in_db_thread).with("account_update")
        end
      end
    end

    describe "run_runner_child_for_tick(3.3-10d)" do
      let(:spawner) { instance_double(Infrastructure::StrategyRunnerChildSpawner) }
      let(:ai_filter_service) { instance_double(Domain::AiFilterService) }
      let(:risk_guard_service) { instance_double(Domain::RiskGuardService) }
      let(:order_endpoint_di) { instance_double(Infrastructure::BitgetOrderEndpoint) }
      let(:worker) do
        described_class.new(
          process_manager: process_manager,
          clock_sync: clock_sync,
          market_endpoint: market_endpoint,
          position_endpoint: position_endpoint,
          public_ws_factory: public_ws_factory,
          private_ws_factory: private_ws_factory,
          runner_child_spawner: spawner,
          ai_filter_service: ai_filter_service,
          risk_guard_service: risk_guard_service,
          order_endpoint: order_endpoint_di,
          main_loop_poll_interval: 0,
          logger: logger
        )
      end
      let(:candle_payload) do
        {
          "ts" => 1_700_000_000_000,
          "open" => "50000", "high" => "50100", "low" => "49900", "close" => "50050"
        }
      end
      let(:order_intent) do
        {
          "side" => "buy",
          "order_type" => "limit",
          "size" => "0.01",
          "price" => "49900",
          "client_oid" => "intent-001"
        }
      end
      let(:intent_without_client_oid) do
        {
          "side" => "buy", "order_type" => "limit", "size" => "0.01", "price" => "49900"
        }
      end
      let(:state_diff) do
        { "ops" => [ { "op" => "replace_all", "value" => { "ema" => 50_050 } } ] }
      end
      let(:spawn_response_ok) do
        {
          "status" => "ok",
          "order_intents" => [ order_intent ],
          "strategy_state_diff" => state_diff,
          "logs" => [],
          "errors" => []
        }
      end

      before do
        # 既存 SessionState を作成して reload race 回避
        LiveTrading::SessionState.create!(live_trading_session_id: session.id, state_data: {})
        allow(spawner).to receive(:run).and_return(spawn_response_ok)
        allow(ai_filter_service).to receive(:call).and_return({ "enter" => true })
        allow(risk_guard_service).to receive(:allow_entry?).and_return(true)
        allow(order_endpoint_di).to receive(:place_order)
      end

      describe "正常パス(spawn ok)" do
        subject { worker.send(:run_runner_child_for_tick, session, candle_payload) }

        it "spawner.run を on_tick + revision + ctx_input(candle/state/position/balance)で呼ぶ" do
          subject
          expect(spawner).to have_received(:run).with(
            callback: :on_tick,
            revision: revision,
            ctx_input: a_hash_including(
              "candle" => candle_payload,
              "state" => {},
              "position" => a_hash_including("side" => nil, "size" => "0.0", "entry_price" => "0.0"),
              "balance" => "0.0"
            )
          )
        end

        it "state_diff (replace_all) が SessionState に適用される" do
          subject
          expect(session.session_state.reload.state_data).to eq({ "ema" => 50_050 })
        end

        it "order_intents の各 intent に対して place_order を呼ぶ" do
          subject
          expect(order_endpoint_di).to have_received(:place_order).with(
            a_hash_including(
              symbol: "BTCUSDT", margin_mode: "isolated", margin_coin: "USDT",
              side: "buy", order_type: "limit", size: "0.01",
              client_oid: "intent-001", price: "49900"
            )
          )
        end

        # R-1 #3 反映: client_oid 未指定時の決定論的 ID 生成
        context "intent に client_oid が無い場合" do
          let(:spawn_response_ok) do
            {
              "status" => "ok",
              "order_intents" => [ intent_without_client_oid ],
              "strategy_state_diff" => state_diff,
              "logs" => [], "errors" => []
            }
          end

          it "決定論的 ID(live-{session_id}-{candle_ts}-{idx})が client_oid に使われる" do
            subject
            expect(order_endpoint_di).to have_received(:place_order).with(
              a_hash_including(client_oid: "live-#{session.id}-#{candle_payload['ts']}-0")
            )
          end
        end
      end

      describe "spawn 失敗パス" do
        context "status=error" do
          before do
            allow(spawner).to receive(:run).and_return(
              "status" => "error", "errors" => [ { "class" => "RuntimeError", "message" => "boom" } ]
            )
          end

          it "logger.warn 落とし + place_order を呼ばない" do
            worker.send(:run_runner_child_for_tick, session, candle_payload)
            expect(logger).to have_received(:warn).with(/non-ok status=error.*RuntimeError/)
            expect(order_endpoint_di).not_to have_received(:place_order)
          end
        end

        context "status=timeout" do
          before do
            allow(spawner).to receive(:run).and_return(
              "status" => "timeout", "errors" => [ { "class" => "TimeoutError" } ]
            )
          end

          it "logger.warn 落とし + place_order を呼ばない" do
            worker.send(:run_runner_child_for_tick, session, candle_payload)
            expect(logger).to have_received(:warn).with(/non-ok status=timeout/)
            expect(order_endpoint_di).not_to have_received(:place_order)
          end
        end
      end

      describe "AI filter 判定" do
        context "revision.ai_filter_enabled = false" do
          # default revision は ai_filter_enabled: false
          it "AI filter を呼ばずに RiskGuard → place_order に進む" do
            worker.send(:run_runner_child_for_tick, session, candle_payload)
            expect(ai_filter_service).not_to have_received(:call)
            expect(order_endpoint_di).to have_received(:place_order)
          end
        end

        context "revision.ai_filter_enabled = true" do
          before do
            revision.update_columns(
              ai_filter_enabled: true,
              ai_filter_template_name: "entry_filter",
              ai_filter_fail_safe: "skip",
              ai_filter_timeout_sec: 3
            )
          end

          context "AI filter 通過(enter=true)" do
            it "place_order が呼ばれる" do
              allow(ai_filter_service).to receive(:call).and_return({ "enter" => true })
              worker.send(:run_runner_child_for_tick, session, candle_payload)
              expect(order_endpoint_di).to have_received(:place_order)
            end
          end

          context "AI filter 否決(enter=false)" do
            it "place_order を呼ばない" do
              allow(ai_filter_service).to receive(:call).and_return({ "enter" => false })
              worker.send(:run_runner_child_for_tick, session, candle_payload)
              expect(order_endpoint_di).not_to have_received(:place_order)
            end
          end

          context "AI filter validation_failed(nil 戻り)" do
            it "place_order を呼ばない(エントリー見送り固定)" do
              allow(ai_filter_service).to receive(:call).and_return(nil)
              worker.send(:run_runner_child_for_tick, session, candle_payload)
              expect(order_endpoint_di).not_to have_received(:place_order)
            end
          end
        end
      end

      describe "RiskGuard 否決" do
        before do
          allow(risk_guard_service).to receive(:allow_entry?).and_return(false)
        end

        it "place_order を呼ばない" do
          worker.send(:run_runner_child_for_tick, session, candle_payload)
          expect(order_endpoint_di).not_to have_received(:place_order)
        end
      end

      describe "process_order_intent 例外時" do
        before do
          allow(order_endpoint_di).to receive(:place_order).and_raise(StandardError, "API error")
        end

        it "logger.warn 落とし + 他 intent の処理を妨げない" do
          # 2 intent ある場合, 1 件目失敗しても 2 件目の評価は継続
          response_with_two = spawn_response_ok.merge(
            "order_intents" => [ order_intent, order_intent.merge("client_oid" => "intent-002") ]
          )
          allow(spawner).to receive(:run).and_return(response_with_two)

          worker.send(:run_runner_child_for_tick, session, candle_payload)

          expect(logger).to have_received(:warn).with(/process_order_intent failed.*API error/).twice
          expect(order_endpoint_di).to have_received(:place_order).twice
        end
      end
    end

    describe "reconciliation(3.3-11 / bootstrap step 11)" do
      before do
        worker.send(:instance_variable_set, :@session, session)
        session.update_column(:status, "starting")
      end

      describe "#run_reconciliation" do
        it "session を starting → reconciling に遷移させる" do
          worker.send(:run_reconciliation, session)
          expect(session.reload.state_reconciling?).to be true
        end

        it "5 件の reconcile 系 method を順次呼び出す" do
          expect(worker).to receive(:reconcile_orders_pending).with(session).ordered
          expect(worker).to receive(:reconcile_orders_plan_pending).with(session).ordered
          expect(worker).to receive(:reconcile_orders_plan_history).with(session).ordered
          expect(worker).to receive(:reconcile_position_all).with(session).ordered

          worker.send(:run_reconciliation, session)
        end
      end

      describe "#reconcile_orders_pending" do
        it "order_endpoint.orders_pending を session.symbol で呼ぶ" do
          worker.send(:reconcile_orders_pending, session)
          expect(order_endpoint_di).to have_received(:orders_pending).with(symbol: "BTCUSDT")
        end

        context "REST 呼出が失敗した場合" do
          before do
            allow(order_endpoint_di).to receive(:orders_pending).and_raise(StandardError, "API down")
          end

          it "logger.warn 落とし + nil 返却(後続 reconcile 継続)" do
            result = worker.send(:reconcile_orders_pending, session)
            expect(result).to be_nil
            expect(logger).to have_received(:warn).with(/reconcile_orders_pending failed.*API down/)
          end
        end
      end

      describe "#reconcile_orders_plan_pending" do
        it "order_endpoint.orders_plan_pending を symbol で呼ぶ" do
          worker.send(:reconcile_orders_plan_pending, session)
          expect(order_endpoint_di).to have_received(:orders_plan_pending).with(symbol: "BTCUSDT")
        end

        context "REST 失敗時" do
          before do
            allow(order_endpoint_di).to receive(:orders_plan_pending).and_raise(StandardError, "boom")
          end

          it "logger.warn + nil 返却" do
            expect(worker.send(:reconcile_orders_plan_pending, session)).to be_nil
            expect(logger).to have_received(:warn).with(/reconcile_orders_plan_pending failed/)
          end
        end
      end

      describe "#reconcile_orders_plan_history" do
        it "直近 24h 範囲(start_time / end_time)で symbol を指定して呼ぶ" do
          fixed_now = Time.utc(2026, 5, 7, 12, 0, 0)
          allow(Time).to receive(:current).and_return(fixed_now)
          end_time_ms = (fixed_now.to_f * 1000).to_i
          start_time_ms = end_time_ms - (24 * 60 * 60 * 1000)

          worker.send(:reconcile_orders_plan_history, session)

          expect(order_endpoint_di).to have_received(:orders_plan_history).with(
            symbol: "BTCUSDT", start_time: start_time_ms, end_time: end_time_ms
          )
        end

        context "REST 失敗時" do
          before do
            allow(order_endpoint_di).to receive(:orders_plan_history).and_raise(StandardError, "boom")
          end

          it "logger.warn + nil 返却" do
            expect(worker.send(:reconcile_orders_plan_history, session)).to be_nil
            expect(logger).to have_received(:warn).with(/reconcile_orders_plan_history failed/)
          end
        end
      end

      describe "#reconcile_position_all" do
        it "position_endpoint.position_all を margin_coin + symbol で呼ぶ" do
          worker.send(:reconcile_position_all, session)
          expect(position_endpoint).to have_received(:position_all).with(
            margin_coin: "USDT", symbol: "BTCUSDT"
          )
        end

        context "REST 失敗時" do
          before do
            allow(position_endpoint).to receive(:position_all).and_raise(StandardError, "boom")
          end

          it "logger.warn + nil 返却" do
            expect(worker.send(:reconcile_position_all, session)).to be_nil
            expect(logger).to have_received(:warn).with(/reconcile_position_all failed/)
          end
        end
      end
    end

    describe "heartbeat / lease renew(3.3-12)" do
      before do
        worker.send(:instance_variable_set, :@session, session)
        worker.send(:instance_variable_set, :@lease, lease)
        worker.send(:instance_variable_set, :@worker_instance_id, "worker-test-001")
      end

      describe "#pulse_heartbeat_if_due" do
        # R-2 #5 反映: monotonic clock 化に伴い数値時刻で経過判定する
        before do
          worker.instance_variable_set(:@monotonic_clock, -> { @stub_now })
          @stub_now = 1000.0
        end

        context "初回呼出(@last_heartbeat_at が nil)" do
          it "process_manager.pulse_heartbeat! を session + worker_instance_id で呼ぶ" do
            worker.send(:pulse_heartbeat_if_due)
            expect(process_manager).to have_received(:pulse_heartbeat!).with(
              session: session, worker_instance_id: "worker-test-001"
            )
          end

          it "@last_heartbeat_at に monotonic_clock の値が記録される" do
            worker.send(:pulse_heartbeat_if_due)
            expect(worker.instance_variable_get(:@last_heartbeat_at)).to eq(1000.0)
          end
        end

        context "前回 heartbeat から 60 秒未経過" do
          before do
            worker.send(:instance_variable_set, :@last_heartbeat_at, 1000.0)
            @stub_now = 1030.0 # 30 秒経過
          end

          it "pulse_heartbeat! を呼ばない" do
            worker.send(:pulse_heartbeat_if_due)
            expect(process_manager).not_to have_received(:pulse_heartbeat!)
          end
        end

        context "前回 heartbeat から 60 秒以上経過" do
          before do
            worker.send(:instance_variable_set, :@last_heartbeat_at, 1000.0)
            @stub_now = 1061.0 # 61 秒経過
          end

          it "pulse_heartbeat! を呼ぶ" do
            worker.send(:pulse_heartbeat_if_due)
            expect(process_manager).to have_received(:pulse_heartbeat!)
          end
        end

        context "pulse_heartbeat! が raise した場合" do
          before do
            allow(process_manager).to receive(:pulse_heartbeat!)
              .and_raise(StandardError, "DB connection lost")
          end

          it "logger.warn 落とし + 例外を再 raise しない" do
            expect { worker.send(:pulse_heartbeat_if_due) }.not_to raise_error
            expect(logger).to have_received(:warn).with(
              /pulse_heartbeat! failed.*DB connection lost/
            )
          end
        end
      end

      describe "#renew_lease_if_due" do
        before do
          worker.instance_variable_set(:@monotonic_clock, -> { @stub_now })
          @stub_now = 2000.0
        end

        context "初回呼出(@last_lease_renew_at が nil)" do
          it "process_manager.renew_lease! を lease で呼ぶ" do
            worker.send(:renew_lease_if_due)
            expect(process_manager).to have_received(:renew_lease!).with(lease: lease)
          end

          it "@last_lease_renew_at に monotonic_clock の値が記録される" do
            worker.send(:renew_lease_if_due)
            expect(worker.instance_variable_get(:@last_lease_renew_at)).to eq(2000.0)
          end
        end

        context "前回 lease renew から 120 秒未経過" do
          before do
            worker.send(:instance_variable_set, :@last_lease_renew_at, 2000.0)
            @stub_now = 2060.0 # 60 秒経過
          end

          it "renew_lease! を呼ばない" do
            worker.send(:renew_lease_if_due)
            expect(process_manager).not_to have_received(:renew_lease!)
          end
        end

        context "前回 lease renew から 120 秒以上経過" do
          before do
            worker.send(:instance_variable_set, :@last_lease_renew_at, 2000.0)
            @stub_now = 2121.0 # 121 秒経過
          end

          it "renew_lease! を呼ぶ" do
            worker.send(:renew_lease_if_due)
            expect(process_manager).to have_received(:renew_lease!)
          end
        end

        context "@lease が nil の場合(防御)" do
          before do
            worker.send(:instance_variable_set, :@lease, nil)
          end

          it "renew_lease! を呼ばない" do
            worker.send(:renew_lease_if_due)
            expect(process_manager).not_to have_received(:renew_lease!)
          end
        end

        context "renew_lease! が raise した場合" do
          before do
            allow(process_manager).to receive(:renew_lease!)
              .and_raise(StandardError, "lease lost")
          end

          it "logger.warn 落とし + 例外を再 raise しない" do
            expect { worker.send(:renew_lease_if_due) }.not_to raise_error
            expect(logger).to have_received(:warn).with(/renew_lease! failed.*lease lost/)
          end
        end
      end

      describe "main loop 統合: 1 iteration で heartbeat / renew_lease が呼ばれる" do
        before do
          first_call = true
          allow(process_manager).to receive(:signal_kill_switch?) do
            if first_call
              first_call = false
              false # 1 回目は false → 1 iteration 通過
            else
              true # 2 回目以降は true → break
            end
          end
        end

        it "1 iteration の中で pulse_heartbeat! と renew_lease! が呼ばれる" do
          worker.perform(session.id)
          expect(process_manager).to have_received(:pulse_heartbeat!).at_least(:once)
          expect(process_manager).to have_received(:renew_lease!).at_least(:once)
        end
      end
    end

    describe "WS reconnect detection + reconciliation 再実行(3.3-13)" do
      before do
        worker.send(:instance_variable_set, :@session, session)
        worker.send(:instance_variable_set, :@public_ws, public_ws)
        worker.send(:instance_variable_set, :@private_ws, private_ws)
        worker.send(:instance_variable_set, :@last_public_ws_reconnect_count, 0)
        worker.send(:instance_variable_set, :@last_private_ws_reconnect_count, 0)
        # run_in_db_thread を同期化(spec hang 回避)
        allow(worker).to receive(:run_in_db_thread) do |_label, &block|
          block.call
        end
      end

      describe "#detect_ws_reconnect_and_reconcile" do
        context "public_ws.reconnect_count が増えていない場合" do
          before do
            allow(public_ws).to receive(:reconnect_count).and_return(0)
            allow(private_ws).to receive(:reconnect_count).and_return(0)
          end

          it "reconciliation を再実行しない" do
            expect(worker).not_to receive(:run_reconciliation_after_reconnect)
            worker.send(:detect_ws_reconnect_and_reconcile)
          end
        end

        context "public_ws.reconnect_count が増えた(1 → 2)場合" do
          before do
            worker.send(:instance_variable_set, :@last_public_ws_reconnect_count, 1)
            allow(public_ws).to receive(:reconnect_count).and_return(2)
            allow(private_ws).to receive(:reconnect_count).and_return(0)
          end

          it "reconciliation 再実行 + logger.info ログ出力" do
            expect(worker).to receive(:run_reconciliation_after_reconnect).with(
              an_object_having_attributes(id: session.id)
            )

            worker.send(:detect_ws_reconnect_and_reconcile)
            expect(logger).to have_received(:info).with(/WS reconnect detected.*public=true/)
          end

          it "@last_public_ws_reconnect_count が更新される" do
            allow(worker).to receive(:run_reconciliation_after_reconnect)
            worker.send(:detect_ws_reconnect_and_reconcile)
            expect(worker.instance_variable_get(:@last_public_ws_reconnect_count)).to eq(2)
          end

          # R-2 #6 反映: public_ws reconnect 検知時は @last_candle_row を nil リセットして
          # 新旧受信 thread の race window を回避する
          it "@last_candle_row を nil にリセットする" do
            allow(worker).to receive(:run_reconciliation_after_reconnect)
            worker.send(:instance_variable_set, :@last_candle_row, [ 1_700_000_000_000, "50000" ])
            worker.send(:detect_ws_reconnect_and_reconcile)
            expect(worker.instance_variable_get(:@last_candle_row)).to be_nil
          end
        end

        context "private_ws.reconnect_count のみ増えた場合" do
          before do
            worker.send(:instance_variable_set, :@last_private_ws_reconnect_count, 0)
            allow(public_ws).to receive(:reconnect_count).and_return(0)
            allow(private_ws).to receive(:reconnect_count).and_return(1)
          end

          it "reconciliation 再実行 + logger.info で private=true 表示" do
            expect(worker).to receive(:run_reconciliation_after_reconnect)
            worker.send(:detect_ws_reconnect_and_reconcile)
            expect(logger).to have_received(:info).with(/private=true/)
          end
        end

        context "@public_ws / @private_ws が nil の場合(防御)" do
          before do
            worker.send(:instance_variable_set, :@public_ws, nil)
            worker.send(:instance_variable_set, :@private_ws, nil)
          end

          it "reconciliation 再実行を呼ばない / nil で raise しない" do
            expect(worker).not_to receive(:run_reconciliation_after_reconnect)
            expect { worker.send(:detect_ws_reconnect_and_reconcile) }.not_to raise_error
          end
        end
      end

      describe "#run_reconciliation_after_reconnect" do
        it "session.start_reconciling! は呼ばずに 4 件 reconcile を呼び出す" do
          expect(session).not_to receive(:start_reconciling!)
          expect(worker).to receive(:reconcile_orders_pending).with(session)
          expect(worker).to receive(:reconcile_orders_plan_pending).with(session)
          expect(worker).to receive(:reconcile_orders_plan_history).with(session)
          expect(worker).to receive(:reconcile_position_all).with(session)

          worker.send(:run_reconciliation_after_reconnect, session)
        end
      end

      describe "#ws_reconnect_count(防御 helper)" do
        it "ws が nil なら 0" do
          expect(worker.send(:ws_reconnect_count, nil)).to eq(0)
        end

        it "ws が reconnect_count に respond しない場合は 0" do
          ws = double("Ws")
          expect(worker.send(:ws_reconnect_count, ws)).to eq(0)
        end

        it "ws.reconnect_count を to_i で返す" do
          ws = double("Ws", reconnect_count: 3)
          expect(worker.send(:ws_reconnect_count, ws)).to eq(3)
        end
      end
    end

    context "worker_instance_id 生成" do
      it "jid なし(直接 perform)実行時は manual- prefix で生成される" do
        worker.perform(session.id)

        expect(process_manager).to have_received(:acquire_lease!).with(
          a_hash_including(worker_instance_id: a_string_starting_with("manual-"))
        )
      end

      # 軽微 obs 3-(a) 反映: jid あり経路の検証
      it "Sidekiq 経由(jid 設定済)実行時は jid 値を採用する" do
        worker.jid = "abc-123-jid-from-sidekiq"
        worker.perform(session.id)

        expect(process_manager).to have_received(:acquire_lease!).with(
          a_hash_including(worker_instance_id: "abc-123-jid-from-sidekiq")
        )
      end

      it "jid が空文字列の場合は manual- prefix にフォールバックする(jid.presence)" do
        worker.jid = ""
        worker.perform(session.id)

        expect(process_manager).to have_received(:acquire_lease!).with(
          a_hash_including(worker_instance_id: a_string_starting_with("manual-"))
        )
      end
    end
  end
end
