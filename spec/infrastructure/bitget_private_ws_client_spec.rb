require "rails_helper"

RSpec.describe Infrastructure::BitgetPrivateWsClient do
  let(:current_time) { [ 0.0 ] }
  let(:clock) { -> { current_time[0] } }
  let(:ws) { instance_double("WebSocket::Client::Simple::Client") }
  let(:ws_factory) { instance_double(Proc) }
  let(:logger) { instance_double(Logger, warn: nil, info: nil, error: nil, debug: nil) }
  let(:registered_callbacks) { {} }
  let(:signer) { instance_double(Infrastructure::BitgetSigner) }
  let(:api_key) { "test-api-key" }
  let(:passphrase) { "test-passphrase" }
  let(:paptrading_enabled) { true }
  let(:url_override) { nil }
  let(:heartbeat_interval) { 30.0 }
  let(:heartbeat_timeout) { 60.0 }
  let(:reconnect_initial_interval) { 1.0 }
  let(:reconnect_max_interval) { 30.0 }
  let(:fake_thread) { instance_double(Thread, kill: nil, join: nil, alive?: false) }
  let(:client) do
    described_class.new(
      api_key: api_key,
      passphrase: passphrase,
      signer: signer,
      paptrading_enabled: paptrading_enabled,
      url: url_override,
      ws_factory: ws_factory,
      clock: clock,
      logger: logger,
      heartbeat_interval: heartbeat_interval,
      heartbeat_timeout: heartbeat_timeout,
      reconnect_initial_interval: reconnect_initial_interval,
      reconnect_max_interval: reconnect_max_interval
    )
  end

  before do
    allow(ws_factory).to receive(:call).and_return(ws)
    allow(ws).to receive(:on) do |event, &blk|
      registered_callbacks[event] = blk
    end
    allow(ws).to receive(:send)
    allow(ws).to receive(:close)
    allow(client).to receive(:wait_until_open)
    allow(client).to receive(:wait_until_login)
    allow(client).to receive(:sleep)
    allow(signer).to receive(:sign).and_return("signed-base64-string")
    allow(Thread).to receive(:new).and_return(fake_thread)
  end

  describe "#connect" do
    subject { client.connect }

    context "Demo URL で接続する場合(paptrading_enabled: true)" do
      let(:paptrading_enabled) { true }

      it "wspap.bitget.com/v2/ws/private で接続し login + 4 callback 登録" do
        expect(ws_factory).to receive(:call).with("wss://wspap.bitget.com/v2/ws/private").and_return(ws)
        subject
        expect(ws).to have_received(:on).with(:message)
        expect(ws).to have_received(:on).with(:open)
        expect(ws).to have_received(:on).with(:close)
        expect(ws).to have_received(:on).with(:error)
      end
    end

    context "本番 URL で接続する場合(paptrading_enabled: false)" do
      let(:paptrading_enabled) { false }

      it "ws.bitget.com/v2/ws/private で接続" do
        expect(ws_factory).to receive(:call).with("wss://ws.bitget.com/v2/ws/private").and_return(ws)
        subject
      end
    end

    context "url を明示指定した場合" do
      let(:url_override) { "wss://custom.example.com/private" }

      it "指定した URL で接続" do
        expect(ws_factory).to receive(:call).with("wss://custom.example.com/private").and_return(ws)
        subject
      end
    end

    context "login メッセージを送信する場合" do
      it "op: login + args に apiKey/passphrase/timestamp/sign を含む JSON を送信" do
        expect(signer).to receive(:sign).with(
          timestamp: an_instance_of(Integer),
          method: "GET",
          request_path: "/user/verify"
        ).and_return("signed-base64-string")

        subject

        expect(ws).to have_received(:send) do |payload|
          parsed = JSON.parse(payload)
          expect(parsed["op"]).to eq("login")
          expect(parsed["args"].first).to include(
            "apiKey" => api_key,
            "passphrase" => passphrase,
            "sign" => "signed-base64-string"
          )
          expect(parsed["args"].first["timestamp"]).to be_a(String)
        end
      end
    end

    # Phase 4.0 #2 sub-commit 2.2 反映: send_login 内で clock_sync.synced_now 経由 timestamp 生成
    # connect 経由ではなく send_login を private 呼び出しで直接検証(wait_until_login の永久 sleep 回避)
    context "clock_sync が DI されている場合の login メッセージ timestamp" do
      let(:clock_sync) { instance_double(Infrastructure::BitgetClockSync, synced_now: Time.at(1_700_000_005)) }
      let(:client_with_cs) do
        described_class.new(
          api_key:, passphrase:, signer:,
          paptrading_enabled:, ws_factory:, clock:, logger:,
          clock_sync: clock_sync
        )
      end

      before do
        client_with_cs.instance_variable_set(:@ws, ws)
      end

      it "send_login で clock_sync.synced_now が呼ばれて offset 反映済 timestamp で signing する" do
        expect(signer).to receive(:sign).with(
          timestamp: 1_700_000_005,
          method: "GET",
          request_path: "/user/verify"
        ).and_return("signed-base64-string")

        client_with_cs.send(:send_login)

        expect(clock_sync).to have_received(:synced_now)
      end
    end

    context "clock_sync が nil の場合の login メッセージ timestamp(既存挙動互換)" do
      before do
        client.instance_variable_set(:@ws, ws)
      end

      it "Time.current にフォールバックして send_login が動作する" do
        expect(signer).to receive(:sign).with(
          timestamp: an_instance_of(Integer),
          method: "GET",
          request_path: "/user/verify"
        ).and_return("signed-base64-string")

        expect { client.send(:send_login) }.not_to raise_error
      end
    end

    context "既に接続中の場合" do
      before { client.connect }

      it "ConnectionError を raise する" do
        expect { subject }.to raise_error(described_class::ConnectionError, /already connected/)
      end
    end
  end

  describe "受信メッセージのディスパッチ" do
    before do
      client.connect
    end

    def deliver_raw(raw)
      registered_callbacks[:message].call(double(data: raw))
    end

    context "login 成功レスポンスを受信した場合" do
      let(:raw) { '{"event":"login","code":0,"msg":""}' }

      it "@login_completed=true / @login_error=nil(後続の wait_until_login が return)" do
        deliver_raw(raw)
        expect(client.instance_variable_get(:@login_completed)).to be true
        expect(client.instance_variable_get(:@login_error)).to be_nil
      end
    end

    context "login 失敗レスポンスを受信した場合" do
      let(:raw) { '{"event":"login","code":30005,"msg":"signature error"}' }

      # multi-agent review R-4 #10 反映: @login_error には code のみ記録し
      # raw msg は logger.warn のみに残す(永続化経路 LoginFailedError → DB failure_reason から msg を分離).
      it "@login_error には code のみが記録される(msg は除外)" do
        deliver_raw(raw)
        expect(client.instance_variable_get(:@login_completed)).to be false
        expect(client.instance_variable_get(:@login_error)).to eq("code=30005")
        expect(client.instance_variable_get(:@login_error)).not_to include("signature error")
      end

      it "raw msg は logger.warn でのみ出力される" do
        deliver_raw(raw)
        expect(logger).to have_received(:warn).with(/login error detail.*signature error/)
      end
    end

    context "orders push を受信した場合" do
      let(:subscription) do
        Infrastructure::BitgetPrivateWsSubscription.new(
          channel: "orders",
          inst_type: "USDT-FUTURES",
          inst_id: "default"
        )
      end
      let(:received_data) { [] }
      let(:raw) do
        '{"action":"snapshot","arg":{"instType":"USDT-FUTURES","channel":"orders","instId":"default"},' \
          '"data":[{"orderId":"12345"}],"ts":1695716059516}'
      end

      before do
        client.subscribe(subscription) { |data, _result| received_data << data }
      end

      it "登録済 callback が data 引数で呼ばれる" do
        deliver_raw(raw)
        expect(received_data).to eq([ [ { "orderId" => "12345" } ] ])
      end
    end

    context "JSON パースエラー" do
      let(:raw) { "not a json" }

      it "logger.warn が呼ばれて例外で落ちない" do
        expect { deliver_raw(raw) }.not_to raise_error
        expect(logger).to have_received(:warn).with(/parse error/)
      end
    end

    context "Unknown frame を受信した場合(レビュー Phase 3.0 obs-8 同等)" do
      let(:raw) { '{"unexpected_top_level":"value"}' }

      it "logger.debug が呼ばれて例外で落ちない" do
        expect { deliver_raw(raw) }.not_to raise_error
        expect(logger).to have_received(:debug).with(/unknown frame/)
      end
    end
  end

  describe "#wait_until_login(login タイムアウト)" do
    # connect は呼ばずに wait_until_login を直接 spec(connect 内の wait_until_login と分離)
    before do
      allow(client).to receive(:wait_until_login).and_call_original
    end

    context "login 完了フラグがセットされる前にタイムアウトする場合" do
      it "LoginFailedError raise" do
        expect { client.send(:wait_until_login, timeout: 0.0, poll_interval: 0.0) }
          .to raise_error(described_class::LoginFailedError, /timeout/)
      end
    end

    context "login_error がセットされている場合" do
      it "LoginFailedError raise(エラーメッセージ含む)" do
        client.instance_variable_set(:@login_error, "code=30005 msg=signature error")
        expect { client.send(:wait_until_login, timeout: 1.0, poll_interval: 0.0) }
          .to raise_error(described_class::LoginFailedError, /signature error/)
      end
    end

    context "login_completed が true の場合" do
      it "正常 return する" do
        client.instance_variable_set(:@login_completed, true)
        expect { client.send(:wait_until_login, timeout: 1.0, poll_interval: 0.0) }
          .not_to raise_error
      end
    end
  end

  describe "#disconnect" do
    subject { client.disconnect(thread_join_timeout: 0.01) }

    context "接続中の場合" do
      before { client.connect }

      it "ws.close が呼ばれて connected? が false になる" do
        subject
        expect(ws).to have_received(:close)
        expect(client.connected?).to be false
      end
    end

    context "接続していない場合" do
      it "例外なく完了する" do
        expect { subject }.not_to raise_error
        expect(client.connected?).to be false
      end
    end
  end

  # Phase 4.0 #1 + 新-中-6 反映: Private 側でも @last_disconnect_reason を記録(Public 同等の対称性)
  describe "#handle_disconnection 経路の @last_disconnect_reason 記録" do
    context ":close reason で handle_disconnection を呼んだ場合" do
      it "last_disconnect_reason reader が :close を返す" do
        allow(client).to receive(:trigger_reconnect)
        client.send(:handle_disconnection, :close)
        expect(client.last_disconnect_reason).to eq(:close)
      end
    end

    context ":error reason で handle_disconnection を呼んだ場合" do
      it "last_disconnect_reason reader が :error を返す" do
        allow(client).to receive(:trigger_reconnect)
        client.send(:handle_disconnection, :error, StandardError.new("e"))
        expect(client.last_disconnect_reason).to eq(:error)
      end
    end

    context "stop_requested=true 状態で handle_disconnection が呼ばれた場合" do
      it "early return で last_disconnect_reason は更新されない" do
        client.instance_variable_set(:@stop_requested, true)
        allow(client).to receive(:trigger_reconnect)
        client.send(:handle_disconnection, :close)
        expect(client.last_disconnect_reason).to be_nil
      end
    end
  end

  describe "#last_disconnect_reason reader" do
    context "初期状態(切断未発生)" do
      it "nil を返す" do
        expect(client.last_disconnect_reason).to be_nil
      end
    end

    context "handle_disconnection 発火後" do
      before do
        allow(client).to receive(:trigger_reconnect)
      end

      it "最後に発火した reason を返す(mutex 同期で thread-safe)" do
        client.send(:handle_disconnection, :close)
        expect(client.last_disconnect_reason).to eq(:close)
        client.send(:handle_disconnection, :error, StandardError.new("e"))
        expect(client.last_disconnect_reason).to eq(:error)
      end
    end
  end

  # multi-agent review Agent 4 高-2 反映: Public spec L522-653 と対称な reconnect_with_backoff 検証
  # sub-commit 1.3(旧 ws.close 完了待機 + 例外 rescue)+ login race(@login_completed リセット)
  describe "#reconnect_with_backoff(Public 対称性 + Private 固有 login 経路)" do
    let(:sleep_calls) { [] }

    before do
      allow(client).to receive(:sleep) { |sec| sleep_calls << sec }
      client.connect
    end

    subject { client.send(:reconnect_with_backoff) }

    context "1 回目接続成功の場合(login + 既存購読再送経路)" do
      it "sleep(初期 interval) → 旧 ws.close → 新接続 → send_login → wait_until_login の流れ" do
        subject
        expect(sleep_calls).to eq([ reconnect_initial_interval ])
        # connect 時 1 回 + reconnect 時 1 回 = 2 回呼ばれる
        expect(ws_factory).to have_received(:call).at_least(:twice)
        # signer.sign は connect 時 1 回 + reconnect 時 1 回 = 2 回以上
        expect(signer).to have_received(:sign).at_least(:twice)
      end
    end

    # multi-agent review Agent 4 中-4 反映: @open_event_received / @login_completed / @login_error リセット検証
    context "reconnect 時に @login_completed / @login_error / @open_event_received がリセットされる場合" do
      before do
        client.instance_variable_set(:@login_completed, true)
        client.instance_variable_set(:@login_error, "previous error")
        client.instance_variable_set(:@open_event_received, true)
      end

      it "reconnect_with_backoff 内で 3 フラグが false / nil にリセットされる" do
        subject
        # reconnect 成功後の状態を確認(send_login + wait_until_login スタブのため @login_completed は false 維持)
        expect(client.instance_variable_get(:@login_error)).to be_nil
      end
    end

    # multi-agent review Agent 4 高-2 反映: sub-commit 1.3 旧 ws.close 完了待機(close → sleep 順序)
    context "冒頭で旧 ws を mutex 内取得して old_ws.close 完了待機してから sleep する場合" do
      let(:old_ws) { ws }

      it "sleep より前に old_ws.close が呼ばれる(順序検証)" do
        call_order = []
        allow(old_ws).to receive(:close) { call_order << :close }
        allow(client).to receive(:sleep) { |sec| call_order << :sleep; sleep_calls << sec }
        subject
        first_close_idx = call_order.index(:close)
        first_sleep_idx = call_order.index(:sleep)
        expect(first_close_idx).not_to be_nil
        expect(first_sleep_idx).not_to be_nil
        expect(first_close_idx).to be < first_sleep_idx
      end
    end

    # multi-agent review Agent 4 高-2 反映: sub-commit 1.3 新-中-2(close 例外 rescue)
    context "旧 ws.close が例外を raise した場合" do
      before do
        allow(ws).to receive(:close).and_raise(StandardError, "close failed unexpectedly")
      end

      it "logger.warn でログ出力し reconnect ループを継続する(spawn thread 死亡防止)" do
        expect { subject }.not_to raise_error
        expect(logger).to have_received(:warn).with(a_string_including("old ws close failed", "close failed unexpectedly"))
      end
    end

    context "stop_requested が初期から true の場合(disconnect 中 reconnect 抑止)" do
      before { client.instance_variable_set(:@stop_requested, true) }

      it "sleep も establish も呼ばれず即座に return する" do
        subject
        expect(sleep_calls).to be_empty
        # connect 時の 1 回のみ
        expect(ws_factory).to have_received(:call).once
      end
    end
  end

  # peer AI sub-commit 1.2 中-1 反映: Private 側でも spawn 経由検証(Public 同等 / 対称性確保)
  describe "#trigger_reconnect での BackgroundThreadRegistry.spawn 経由起動" do
    let(:background_thread_registry) { instance_double(Domain::BackgroundThreadRegistry) }
    let(:client_with_btr) do
      described_class.new(
        api_key: "test_api_key",
        passphrase: "test_passphrase",
        signer: instance_double(Infrastructure::BitgetSigner, sign: "signed-base64-string"),
        paptrading_enabled: true,
        ws_factory: ws_factory,
        clock: clock,
        logger: logger,
        background_thread_registry: background_thread_registry
      )
    end

    before do
      allow(client_with_btr).to receive(:reconnect_with_backoff)
      allow(background_thread_registry).to receive(:spawn)
    end

    context "background_thread_registry が DI されている場合" do
      subject { client_with_btr.send(:trigger_reconnect, :close) }

      it "background_thread_registry.spawn が bitget_private_ws_reconnect label で呼ばれる" do
        subject
        expect(background_thread_registry).to have_received(:spawn).with("bitget_private_ws_reconnect")
      end

      it "trigger_reconnect 自体は reconnect_with_backoff を同期実行しない(callback スレッド即返却)" do
        subject
        expect(client_with_btr).not_to have_received(:reconnect_with_backoff)
      end
    end

    context "background_thread_registry が nil の場合(LiveTradingWorker DI 接続前 既存挙動互換 / 低-1)" do
      subject { client.send(:trigger_reconnect, :close) }

      before do
        allow(client).to receive(:reconnect_with_backoff)
      end

      it "reconnect_with_backoff を同期実行する(既存挙動維持)" do
        subject
        expect(client).to have_received(:reconnect_with_backoff)
      end
    end

    context "callback 連続発火しても受信スレッドが健全性を維持する場合(中-2 強化)" do
      it "handle_disconnection を 5 連続発火しても各々 spawn が呼ばれ callback スレッド即返却" do
        5.times { client_with_btr.send(:handle_disconnection, :close) }
        expect(background_thread_registry).to have_received(:spawn)
          .with("bitget_private_ws_reconnect").exactly(5).times
      end
    end
  end
end
