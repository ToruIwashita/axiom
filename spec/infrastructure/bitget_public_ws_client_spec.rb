require "rails_helper"

RSpec.describe Infrastructure::BitgetPublicWsClient do
  let(:current_time) { [ 0.0 ] }
  let(:clock) { -> { current_time[0] } }
  let(:ws) { instance_double("WebSocket::Client::Simple::Client") }
  let(:ws_factory) { ->(_url) { ws } }
  let(:logger) { instance_double(Logger, warn: nil, info: nil) }
  let(:registered_callbacks) { {} }
  let(:paptrading_enabled) { true }
  let(:url_override) { nil }
  let(:client) do
    described_class.new(
      paptrading_enabled: paptrading_enabled,
      url: url_override,
      ws_factory: ws_factory,
      clock: clock,
      logger: logger
    )
  end

  before do
    allow(ws).to receive(:on) do |event, &blk|
      registered_callbacks[event] = blk
    end
    allow(ws).to receive(:send)
    allow(ws).to receive(:close)
    allow(client).to receive(:wait_until_open)
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
