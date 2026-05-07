require "rails_helper"

RSpec.describe LiveTradingWorker do
  let(:process_manager) { instance_double(Domain::LiveTradingProcessManager) }
  let(:lease) { instance_double(LiveTrading::SessionLease) }
  let(:logger) { instance_double(Logger, warn: nil, info: nil, error: nil, debug: nil) }
  let(:clock_sync) { instance_double(Infrastructure::BitgetClockSync) }
  let(:market_endpoint) { instance_double(Infrastructure::BitgetMarketEndpoint) }
  let(:position_endpoint) { instance_double(Infrastructure::BitgetPositionEndpoint) }
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
  let(:worker) do
    described_class.new(
      process_manager: process_manager,
      clock_sync: clock_sync,
      market_endpoint: market_endpoint,
      position_endpoint: position_endpoint,
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
    context "step 1-8 全成功(現時点 3.3-9b で実装済の範囲)" do
      it "process_manager.acquire_lease! を session + worker_instance_id で呼ぶ" do
        worker.perform(session.id)

        expect(process_manager).to have_received(:acquire_lease!).with(
          session: an_object_having_attributes(id: session.id),
          worker_instance_id: a_kind_of(String)
        )
      end

      it "session の status は starting のまま(step 13 mark_running は 3.3-9d で実装)" do
        worker.perform(session.id)
        expect(session.reload.state_starting?).to be true
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
        # (3.3-9a スコープでは step 5+ への到達が無いため, unit-level で cleanup を検証)
        worker.send(:cleanup_on_failure,
                    session: session,
                    lease: lease,
                    error: StandardError.new("step 5+ failure"))

        expect(logger).to have_received(:warn).with(
          /lease.release! failed during cleanup_on_failure.*release timeout/
        )
        expect(session.reload.state_failed_to_start?).to be true
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
