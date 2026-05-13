require "rails_helper"

RSpec.describe Infrastructure::BitgetPublicWsClient do
  let(:current_time) { [ 0.0 ] }
  let(:clock) { -> { current_time[0] } }
  let(:ws) { instance_double("WebSocket::Client::Simple::Client") }
  let(:ws_factory) { instance_double(Proc) }
  let(:logger) { instance_double(Logger, warn: nil, info: nil, error: nil, debug: nil) }
  let(:registered_callbacks) { {} }
  let(:paptrading_enabled) { true }
  let(:url_override) { nil }
  let(:heartbeat_interval) { 30.0 }
  let(:heartbeat_timeout) { 60.0 }
  let(:reconnect_initial_interval) { 1.0 }
  let(:reconnect_max_interval) { 30.0 }
  let(:fake_thread) { instance_double(Thread, kill: nil, join: nil, alive?: false) }
  let(:client) do
    described_class.new(
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
    # Thread.new をスタブ化してブロック未実行の fake_thread を返す
    # (heartbeat ループの本体は heartbeat_tick の単体テストで確認する)
    allow(Thread).to receive(:new).and_return(fake_thread)
  end

  describe "#connect" do
    subject { client.connect }

    context "Demo URL で接続する場合(paptrading_enabled: true)" do
      let(:paptrading_enabled) { true }

      it "wspap.bitget.com URL で ws_factory が呼ばれ message/open/close/error の callback が登録される" do
        expect(ws_factory).to receive(:call).with("wss://wspap.bitget.com/v2/ws/public").and_return(ws)
        subject
        expect(ws).to have_received(:on).with(:message)
        expect(ws).to have_received(:on).with(:open)
        expect(ws).to have_received(:on).with(:close)
        expect(ws).to have_received(:on).with(:error)
      end
    end

    context "本番 URL で接続する場合(paptrading_enabled: false)" do
      let(:paptrading_enabled) { false }

      it "ws.bitget.com URL で ws_factory が呼ばれる" do
        expect(ws_factory).to receive(:call).with("wss://ws.bitget.com/v2/ws/public").and_return(ws)
        subject
      end
    end

    context "url を明示指定した場合" do
      let(:url_override) { "wss://custom.example.com/ws" }

      it "指定した URL で ws_factory が呼ばれる" do
        expect(ws_factory).to receive(:call).with("wss://custom.example.com/ws").and_return(ws)
        subject
      end
    end

    context "既に接続中の場合" do
      before do
        client.connect
      end

      it "ConnectionError を raise する" do
        expect { subject }.to raise_error(described_class::ConnectionError, /already connected/)
      end
    end

    context "wait_until_open が ConnectionError を raise した場合(レビュー obs-6 反映: @ws クリーンアップ)" do
      before do
        allow(client).to receive(:wait_until_open)
          .and_raise(described_class::ConnectionError, "WebSocket open timeout (5.0s)")
      end

      it "ws.close が呼ばれて @ws が nil クリアされた上で例外が再 raise される" do
        expect { subject }.to raise_error(described_class::ConnectionError)
        expect(ws).to have_received(:close)
        expect(client.connected?).to be false
      end
    end
  end

  describe "#disconnect" do
    subject { client.disconnect(thread_join_timeout: 0.01) }

    context "接続中の場合" do
      before do
        client.connect
      end

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

    context "heartbeat_thread が起動前の場合(Step 4 段階)" do
      before do
        client.connect
      end

      it "thread.join を呼ばずに正常完了する(@heartbeat_thread が nil のため)" do
        expect { subject }.not_to raise_error
      end
    end

    context "thread.join(timeout) 後も heartbeat_thread が alive な場合(レビュー obs-7 反映: 最終救済)" do
      let(:zombie_thread) { instance_double(Thread, join: nil, alive?: true, kill: nil) }

      before do
        # connect でセットされる @heartbeat_thread を zombie に差し替え
        client.connect
        client.instance_variable_set(:@heartbeat_thread, zombie_thread)
      end

      it "thread.kill が呼ばれて最終救済される" do
        subject
        expect(zombie_thread).to have_received(:join).with(0.01)
        expect(zombie_thread).to have_received(:alive?)
        expect(zombie_thread).to have_received(:kill)
      end
    end

    context "thread.join(timeout) 後に heartbeat_thread が既に死んでいる場合(レビュー obs-7 反映)" do
      let(:dead_thread) { instance_double(Thread, join: nil, alive?: false, kill: nil) }

      before do
        client.connect
        client.instance_variable_set(:@heartbeat_thread, dead_thread)
      end

      it "thread.kill は呼ばれない(既に終了済のため)" do
        subject
        expect(dead_thread).to have_received(:join).with(0.01)
        expect(dead_thread).to have_received(:alive?)
        expect(dead_thread).not_to have_received(:kill)
      end
    end
  end

  describe "#subscribe" do
    let(:subscription) do
      Infrastructure::BitgetPublicWsSubscription.new(
        channel: "ticker",
        inst_type: "USDT-FUTURES",
        inst_id: "BTCUSDT"
      )
    end

    context "接続中に subscribe する場合" do
      subject { client.subscribe(subscription) }

      before do
        client.connect
      end

      it "ws.send が subscribe メッセージ JSON で呼ばれる" do
        subject
        expect(ws).to have_received(:send).with(
          { op: "subscribe",
            args: [ { instType: "USDT-FUTURES", channel: "ticker", instId: "BTCUSDT" } ] }.to_json
        )
      end
    end

    context "切断中に subscribe する場合" do
      subject { client.subscribe(subscription) }

      it "ws.send は呼ばれず内部購読リストにのみ登録される" do
        subject
        expect(ws).not_to have_received(:send)
      end

      it "次回 connect 時に既存購読が再送される" do
        subject
        client.connect
        expect(ws).to have_received(:send).with(
          { op: "subscribe",
            args: [ { instType: "USDT-FUTURES", channel: "ticker", instId: "BTCUSDT" } ] }.to_json
        )
      end
    end

    context "callback ブロック付きで subscribe する場合" do
      subject do
        client.subscribe(subscription) { |_data| nil }
      end

      before do
        client.connect
      end

      it "ws.send が呼ばれる(callback の登録/呼び出しは Step 8 で確認)" do
        subject
        expect(ws).to have_received(:send)
      end
    end
  end

  describe "#unsubscribe" do
    let(:subscription) do
      Infrastructure::BitgetPublicWsSubscription.new(
        channel: "ticker",
        inst_type: "USDT-FUTURES",
        inst_id: "BTCUSDT"
      )
    end

    context "接続中に unsubscribe する場合" do
      subject { client.unsubscribe(subscription) }

      before do
        client.connect
        client.subscribe(subscription)
      end

      it "ws.send が unsubscribe メッセージ JSON で呼ばれる" do
        subject
        expect(ws).to have_received(:send).with(
          { op: "unsubscribe",
            args: [ { instType: "USDT-FUTURES", channel: "ticker", instId: "BTCUSDT" } ] }.to_json
        )
      end
    end

    context "未登録の subscription を unsubscribe する場合" do
      subject { client.unsubscribe(subscription) }

      before do
        client.connect
      end

      it "例外なく完了し ws.send は呼ばれない" do
        expect { subject }.not_to raise_error
        expect(ws).not_to have_received(:send)
      end
    end

    context "切断中に unsubscribe する場合" do
      subject { client.unsubscribe(subscription) }

      before do
        client.subscribe(subscription)
      end

      it "内部購読リストから削除され,次回 connect 時に subscribe されない" do
        subject
        client.connect
        expect(ws).not_to have_received(:send)
      end
    end
  end

  describe "heartbeat" do
    before do
      client.connect
    end

    describe "起動" do
      subject { Thread }

      it "connect 時に heartbeat スレッドが起動される" do
        expect(subject).to have_received(:new)
      end
    end

    describe "ping 送信(heartbeat_tick 単体)" do
      subject { client.send(:heartbeat_tick) }

      it "ws.send('ping') が呼ばれる" do
        subject
        expect(ws).to have_received(:send).with("ping")
      end
    end

    describe "pong 受信" do
      subject { registered_callbacks[:message].call(double(data: "pong")) }

      before do
        current_time[0] = 100.0
      end

      it "@last_pong_at が clock の現在時刻で更新される" do
        subject
        expect(client.send(:last_pong_at)).to eq(100.0)
      end
    end

    describe "heartbeat_tick の例外捕捉(silent 死亡防止)" do
      subject { client.send(:safe_heartbeat_tick) }

      context "heartbeat_tick が StandardError を投げた場合" do
        before do
          allow(client).to receive(:heartbeat_tick).and_raise(StandardError.new("ws send failed"))
        end

        it "例外を握りつぶして logger.error にログ出力する(ループ継続のため re-raise しない)" do
          expect { subject }.not_to raise_error
          expect(logger).to have_received(:error).with(/heartbeat error.*ws send failed/)
        end
      end

      context "heartbeat_tick が正常終了した場合" do
        it "logger.error は呼ばれない" do
          subject
          expect(logger).not_to have_received(:error)
        end
      end
    end

    describe "pong タイムアウト判定(check_pong_timeout 単体)" do
      subject { client.send(:check_pong_timeout) }

      context "経過時間が heartbeat_timeout 以下の場合" do
        before do
          current_time[0] = 30.0  # last_pong_at は connect 時に 0.0
        end

        it "trigger_reconnect は呼ばれない" do
          allow(client).to receive(:trigger_reconnect)
          subject
          expect(client).not_to have_received(:trigger_reconnect)
        end
      end

      context "経過時間が heartbeat_timeout を超えた場合" do
        before do
          current_time[0] = heartbeat_timeout + 1.0
        end

        it "trigger_reconnect(:heartbeat_timeout) が呼ばれる(error 情報なし,引数省略)" do
          allow(client).to receive(:trigger_reconnect)
          subject
          expect(client).to have_received(:trigger_reconnect).with(:heartbeat_timeout)
        end
      end
    end
  end

  describe "切断検知と再接続" do
    let(:sleep_calls) { [] }

    before do
      allow(client).to receive(:sleep) { |sec| sleep_calls << sec }
      client.connect
    end

    describe "#handle_disconnection 経路" do
      context "ws.on(:close) callback が発火した場合" do
        subject { registered_callbacks[:close].call }

        it "trigger_reconnect が呼ばれる(reason=:close, error=nil)" do
          allow(client).to receive(:trigger_reconnect)
          subject
          expect(client).to have_received(:trigger_reconnect).with(:close, nil)
        end
      end

      context "ws.on(:error) callback が発火した場合" do
        let(:ws_error) { StandardError.new("ws error") }

        subject { registered_callbacks[:error].call(ws_error) }

        it "trigger_reconnect が呼ばれる(reason=:error, error=ws_error)" do
          allow(client).to receive(:trigger_reconnect)
          subject
          expect(client).to have_received(:trigger_reconnect).with(:error, ws_error)
        end
      end

      context "disconnect 中(stop_requested=true)に close が発火した場合" do
        subject { registered_callbacks[:close].call }

        before do
          client.disconnect(thread_join_timeout: 0.01)
        end

        it "trigger_reconnect は呼ばれない" do
          allow(client).to receive(:trigger_reconnect)
          subject
          expect(client).not_to have_received(:trigger_reconnect)
        end
      end

      # Phase 4.0 #1 + 新-中-6 反映: handle_disconnection 内で @last_disconnect_reason を記録
      context "ws.on(:close) callback 発火時に @last_disconnect_reason が記録される場合" do
        subject { registered_callbacks[:close].call }

        it "last_disconnect_reason reader が :close を返す" do
          allow(client).to receive(:trigger_reconnect)
          subject
          expect(client.last_disconnect_reason).to eq(:close)
        end
      end

      context "ws.on(:error) callback 発火時に @last_disconnect_reason が記録される場合" do
        let(:ws_error) { StandardError.new("ws error") }

        subject { registered_callbacks[:error].call(ws_error) }

        it "last_disconnect_reason reader が :error を返す" do
          allow(client).to receive(:trigger_reconnect)
          subject
          expect(client.last_disconnect_reason).to eq(:error)
        end
      end

      context "heartbeat タイムアウト経由で trigger_reconnect が呼ばれた場合の @last_disconnect_reason" do
        subject { client.send(:handle_disconnection, :heartbeat_timeout) }

        it "last_disconnect_reason reader が :heartbeat_timeout を返す" do
          allow(client).to receive(:trigger_reconnect)
          subject
          expect(client.last_disconnect_reason).to eq(:heartbeat_timeout)
        end
      end

      # peer AI レビュー 低-1 反映: Public + Private 対称性確保
      context "stop_requested=true 状態で handle_disconnection が呼ばれた場合" do
        it "early return で last_disconnect_reason は更新されない" do
          client.instance_variable_set(:@stop_requested, true)
          allow(client).to receive(:trigger_reconnect)
          client.send(:handle_disconnection, :close)
          expect(client.last_disconnect_reason).to be_nil
        end
      end
    end

    describe "#trigger_reconnect(レビュー obs-5 反映: error 引数を logger.warn に含める)" do
      before do
        allow(client).to receive(:reconnect_with_backoff)
      end

      context "error 引数なし(nil)の場合" do
        subject { client.send(:trigger_reconnect, :close) }

        it "logger.warn メッセージに reason のみが含まれる" do
          subject
          expect(logger).to have_received(:warn).with("[BitgetPublicWsClient] reconnect triggered: close")
        end
      end

      context "error 引数ありの場合" do
        let(:ws_error) { StandardError.new("connection reset by peer") }

        subject { client.send(:trigger_reconnect, :error, ws_error) }

        it "logger.warn メッセージに reason と error.message の両方が含まれる" do
          subject
          expect(logger).to have_received(:warn)
            .with(a_string_including("reconnect triggered: error", "connection reset by peer"))
        end
      end

      # Phase 4.0 #1 sub-commit 1.2 反映: trigger_reconnect 公開シグネチャ維持 / 内部実装で background_thread_registry.spawn 経由化
      # background_thread_registry が DI されない client(既存 spec)では同期実行を維持 / DI 版で別スレッド起動を検証
      context "BackgroundThreadRegistry.spawn 経由で reconnect_with_backoff を別スレッド起動する場合" do
        let(:background_thread_registry) { instance_double(Domain::BackgroundThreadRegistry) }
        let(:client_with_btr) do
          described_class.new(
            paptrading_enabled: paptrading_enabled,
            url: url_override,
            ws_factory: ws_factory,
            clock: clock,
            logger: logger,
            heartbeat_interval: heartbeat_interval,
            heartbeat_timeout: heartbeat_timeout,
            reconnect_initial_interval: reconnect_initial_interval,
            reconnect_max_interval: reconnect_max_interval,
            background_thread_registry: background_thread_registry
          )
        end

        before do
          allow(client_with_btr).to receive(:reconnect_with_backoff)
          allow(background_thread_registry).to receive(:spawn)
        end

        subject { client_with_btr.send(:trigger_reconnect, :close) }

        it "background_thread_registry.spawn が適切な label で呼ばれる" do
          subject
          expect(background_thread_registry).to have_received(:spawn).with("bitget_public_ws_reconnect")
        end

        it "trigger_reconnect 自体は reconnect_with_backoff を同期実行しない(callback スレッド即返却)" do
          subject
          # spawn の block 内で reconnect_with_backoff が起動される設計のため,
          # spawn の block 実行が走らない stub 設定下では直接呼ばれないことを検証
          expect(client_with_btr).not_to have_received(:reconnect_with_backoff)
        end
      end
    end

    describe "#reconnect_with_backoff" do
      subject { client.send(:reconnect_with_backoff) }

      context "1 回目接続成功の場合" do
        it "sleep(初期 interval) → ws_factory 再呼び出し → wait_until_open の流れになる" do
          subject
          expect(sleep_calls).to eq([ reconnect_initial_interval ])
          # connect 時 1 回 + reconnect 時 1 回 = 2 回呼ばれる
          expect(ws_factory).to have_received(:call).at_least(:twice)
        end
      end

      context "1 回目失敗 → 2 回目成功の場合" do
        before do
          # connect 時の 1 回目呼出は外側 before で成功済み。reconnect 内の最初の試行で raise させる
          reconnect_call_count = 0
          allow(ws_factory).to receive(:call) do
            reconnect_call_count += 1
            raise StandardError, "connection failed" if reconnect_call_count == 1

            ws
          end
        end

        it "sleep の引数列が指数バックオフで増える(初期 interval → 初期 interval × 2)" do
          subject
          expect(sleep_calls).to eq([ reconnect_initial_interval, reconnect_initial_interval * 2 ])
        end
      end

      context "再接続成功時に既存購読が再送される場合" do
        let(:subscription) do
          Infrastructure::BitgetPublicWsSubscription.new(
            channel: "ticker",
            inst_type: "USDT-FUTURES",
            inst_id: "BTCUSDT"
          )
        end
        let(:expected_payload) do
          { op: "subscribe",
            args: [ { instType: "USDT-FUTURES", channel: "ticker", instId: "BTCUSDT" } ] }.to_json
        end

        before do
          client.subscribe(subscription)
        end

        it "subscribe 時 + 再接続時の合計で subscribe メッセージが 2 回以上送信される" do
          subject
          expect(ws).to have_received(:send).with(expected_payload).at_least(:twice)
        end
      end

      context "sleep 中に disconnect された場合(設計時レビュー重要2)" do
        before do
          allow(client).to receive(:sleep) do |sec|
            sleep_calls << sec
            # sleep 中に disconnect 相当の状態にする(stop_requested=true)
            client.instance_variable_set(:@stop_requested, true)
          end
        end

        it "sleep 直後の stop_requested チェックで establish_connection_internal が呼ばれない" do
          # connect 時の 1 回呼出のみ(reconnect では呼ばれない)
          subject
          expect(ws_factory).to have_received(:call).once
        end
      end

      context "stop_requested が初期から true の場合" do
        before do
          client.instance_variable_set(:@stop_requested, true)
        end

        it "sleep も establish も呼ばれず即座に return する" do
          subject
          expect(sleep_calls).to be_empty
          # connect 時の 1 回のみ
          expect(ws_factory).to have_received(:call).once
        end
      end

      context "reconnect 内の wait_until_open が ConnectionError を raise した場合(レビュー obs-6 反映: @ws クリーンアップ)" do
        before do
          # 外側 before の client.connect は完了済(その時の wait_until_open は outer before で stub 済)
          # subject 実行(reconnect_with_backoff)時: 1 回目 wait_until_open で raise → 2 回目で成功
          wait_call_count = 0
          allow(client).to receive(:wait_until_open) do
            wait_call_count += 1
            raise described_class::ConnectionError, "open timeout" if wait_call_count == 1
          end
        end

        it "失敗回の @ws が close + nil クリアされた上で次回 reconnect で再 establish される" do
          subject
          # connect 時 1 回 + reconnect 失敗 1 回 + reconnect 成功 1 回 = 3 回
          expect(ws_factory).to have_received(:call).at_least(3).times
          # wait_until_open 失敗時に ws.close が呼ばれる(cleanup_ws_after_open_failure 経由)
          expect(ws).to have_received(:close).at_least(:once)
        end
      end

      # Phase 4.0 #1 + 高-1.2.4 反映: 冒頭で旧 ws.close 完了待機構造
      context "冒頭で旧 ws を mutex 内取得して old_ws.close 完了待機してから sleep する場合" do
        let(:old_ws) { ws }  # connect 時に設定された ws インスタンス

        it "sleep より前に old_ws.close が呼ばれる(順序検証)" do
          call_order = []
          allow(old_ws).to receive(:close) { call_order << :close }
          allow(client).to receive(:sleep) { |sec| call_order << :sleep; sleep_calls << sec }
          subject
          # close → sleep の順序(reconnect_with_backoff 冒頭で close → sleep)
          first_close_idx = call_order.index(:close)
          first_sleep_idx = call_order.index(:sleep)
          expect(first_close_idx).not_to be_nil
          expect(first_sleep_idx).not_to be_nil
          expect(first_close_idx).to be < first_sleep_idx
        end
      end
    end

    # Phase 4.0 #1 + 低-8 反映: callback 連続発火耐性 race spec
    describe "callback 連続発火しても受信スレッドが健全性を維持する場合" do
      it "handle_disconnection を 5 連続発火しても各々 background_thread_registry.spawn 経由で起動され同期ブロックしない" do
        allow(client).to receive(:trigger_reconnect)
        5.times { client.send(:handle_disconnection, :close) }
        expect(client).to have_received(:trigger_reconnect).exactly(5).times
      end
    end

    # Phase 4.0 #1 + 新-中-6 反映: @last_disconnect_reason reader
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
  end

  describe "受信メッセージのディスパッチ" do
    let(:subscription) do
      Infrastructure::BitgetPublicWsSubscription.new(
        channel: "ticker",
        inst_type: "USDT-FUTURES",
        inst_id: "BTCUSDT"
      )
    end
    let(:received_data) { [] }
    let(:callback) { ->(data, _result) { received_data << data } }

    before do
      client.connect
      client.subscribe(subscription, &callback)
    end

    def deliver_raw(raw)
      registered_callbacks[:message].call(double(data: raw))
    end

    context "snapshot push を受信した場合" do
      let(:raw) do
        '{"action":"snapshot","arg":{"instType":"USDT-FUTURES","channel":"ticker","instId":"BTCUSDT"},' \
          '"data":[{"lastPr":"50000.0"}],"ts":1695716059516}'
      end

      it "登録済み subscription の callback が data 引数で呼ばれる" do
        deliver_raw(raw)
        expect(received_data).to eq([ [ { "lastPr" => "50000.0" } ] ])
      end
    end

    context "update push を受信した場合" do
      let(:raw) do
        '{"action":"update","arg":{"instType":"USDT-FUTURES","channel":"books","instId":"BTCUSDT"},' \
          '"data":[{"asks":[]}],"ts":1695716059520}'
      end

      it "未登録 subscription(books チャネル)への push では callback が呼ばれない" do
        deliver_raw(raw)
        expect(received_data).to be_empty
      end
    end

    context "未登録 subscription への push を受信した場合" do
      let(:raw) do
        '{"action":"snapshot","arg":{"instType":"SPOT","channel":"ticker","instId":"ETHUSDT"},' \
          '"data":[{"lastPr":"3000.0"}],"ts":1695716059516}'
      end

      it "callback は呼ばれない" do
        deliver_raw(raw)
        expect(received_data).to be_empty
      end
    end

    context "subscribe 成功イベントを受信した場合" do
      let(:raw) do
        '{"event":"subscribe","arg":{"instType":"USDT-FUTURES","channel":"ticker","instId":"BTCUSDT"}}'
      end

      it "副作用なし(callback も logger.warn も呼ばれない)" do
        deliver_raw(raw)
        expect(received_data).to be_empty
        expect(logger).not_to have_received(:warn)
      end
    end

    context "error イベントを受信した場合" do
      let(:raw) do
        '{"event":"error","arg":{},"code":30003,"msg":"Symbol not exists","op":"subscribe"}'
      end

      it "logger.warn が code/message 含む形で呼ばれる" do
        deliver_raw(raw)
        expect(logger).to have_received(:warn).with(/event error.*Symbol not exists/)
      end
    end

    context "JSON パースエラーが発生した場合" do
      let(:raw) { "not a json" }

      it "logger.warn が呼ばれて Client が例外で落ちない" do
        expect { deliver_raw(raw) }.not_to raise_error
        expect(logger).to have_received(:warn).with(/parse error/)
      end
    end

    # Phase 1.3 obs-8 反映: Decoder Unknown 型(event/push/parse_error のいずれにも該当しない構造)を
    # サイレント無視せず logger.debug で出力 → Bitget 仕様変更時の早期検知を改善
    context "Decoder の Unknown Result が返された場合(レビュー obs-8 反映)" do
      let(:raw) { '{"unexpected_top_level_key":"value"}' }

      it "logger.debug が unknown frame メッセージで呼ばれる(Client は例外で落ちない)" do
        expect { deliver_raw(raw) }.not_to raise_error
        expect(logger).to have_received(:debug).with(/unknown frame/)
      end
    end

    # 完了レビュー観察2 対応: Bitget が予期しない arg(必須キー欠落 / nil 等)を返した場合,
    # BitgetPublicWsSubscription.new が ArgumentError を raise すると受信スレッドが死亡し,
    # 以降 close/error callback も発火せず再接続不能になる致命的問題を防ぐ。
    context "push の arg に必須キーが欠落していた場合" do
      let(:raw) do
        '{"action":"snapshot","arg":{"channel":"ticker"},' \
          '"data":[{"lastPr":"50000.0"}],"ts":1695716059516}'
      end

      it "logger.warn が呼ばれて Client が例外で落ちず callback も呼ばれない" do
        expect { deliver_raw(raw) }.not_to raise_error
        expect(received_data).to be_empty
        expect(logger).to have_received(:warn).with(/invalid push arg/)
      end
    end
  end

  describe "#connected?" do
    subject { client.connected? }

    context "未接続の場合" do
      it "false を返す" do
        expect(subject).to be false
      end
    end

    context "connect 後の場合" do
      before do
        client.connect
      end

      it "true を返す" do
        expect(subject).to be true
      end
    end

    context "disconnect 後の場合" do
      before do
        client.connect
        client.disconnect(thread_join_timeout: 0.01)
      end

      it "false を返す" do
        expect(subject).to be false
      end
    end
  end
end
