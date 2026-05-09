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
end
