require "rails_helper"

RSpec.describe Infrastructure::BitgetPublicWsClient do
  let(:current_time) { [ 0.0 ] }
  let(:clock) { -> { current_time[0] } }
  let(:ws) { instance_double("WebSocket::Client::Simple::Client") }
  let(:ws_factory) { instance_double(Proc) }
  let(:logger) { instance_double(Logger, warn: nil, info: nil, error: nil) }
  let(:registered_callbacks) { {} }
  let(:paptrading_enabled) { true }
  let(:url_override) { nil }
  let(:heartbeat_interval) { 30.0 }
  let(:heartbeat_timeout) { 60.0 }
  let(:reconnect_initial_interval) { 1.0 }
  let(:reconnect_max_interval) { 30.0 }
  let(:fake_thread) { instance_double(Thread, kill: nil, join: nil) }
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

        it "trigger_reconnect(:heartbeat_timeout) が呼ばれる" do
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

        it "trigger_reconnect が呼ばれる(reason=:close)" do
          allow(client).to receive(:trigger_reconnect)
          subject
          expect(client).to have_received(:trigger_reconnect).with(:close)
        end
      end

      context "ws.on(:error) callback が発火した場合" do
        subject { registered_callbacks[:error].call(StandardError.new("ws error")) }

        it "trigger_reconnect が呼ばれる(reason=:error)" do
          allow(client).to receive(:trigger_reconnect)
          subject
          expect(client).to have_received(:trigger_reconnect).with(:error)
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
