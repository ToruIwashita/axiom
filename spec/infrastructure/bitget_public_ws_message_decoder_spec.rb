require "rails_helper"

RSpec.describe Infrastructure::BitgetPublicWsMessageDecoder do
  describe ".decode" do
    subject { described_class.decode(raw) }

    context "subscribe 成功イベントの場合" do
      let(:raw) do
        '{"event":"subscribe","arg":{"instType":"USDT-FUTURES","channel":"ticker","instId":"BTCUSDT"}}'
      end

      it "Event 型を返し event_name=subscribe / error?=false / 述語が正しく分岐する" do
        result = subject
        expect(result.event?).to be true
        expect(result.push?).to be false
        expect(result.unknown?).to be false
        expect(result.parse_error?).to be false
        expect(result.event_name).to eq("subscribe")
        expect(result.error?).to be false
        expect(result.arg).to eq("instType" => "USDT-FUTURES", "channel" => "ticker", "instId" => "BTCUSDT")
        expect(result.raw).to eq(raw)
      end
    end

    context "unsubscribe 成功イベントの場合" do
      let(:raw) do
        '{"event":"unsubscribe","arg":{"instType":"USDT-FUTURES","channel":"ticker","instId":"BTCUSDT"}}'
      end

      it "Event 型を返し event_name=unsubscribe / error?=false となる" do
        result = subject
        expect(result.event?).to be true
        expect(result.event_name).to eq("unsubscribe")
        expect(result.error?).to be false
      end
    end

    context "error イベントの場合" do
      let(:raw) do
        '{"event":"error","arg":{"instType":"SP","channel":"ticker","instId":"BTC-USDT"},' \
          '"code":30003,"msg":"Symbol not exists","op":"subscribe"}'
      end

      it "Event 型を返し error?=true / code / message を保持する" do
        result = subject
        expect(result.event?).to be true
        expect(result.error?).to be true
        expect(result.code).to eq(30003)
        expect(result.message).to eq("Symbol not exists")
      end
    end

    context "snapshot push の場合" do
      let(:raw) do
        '{"action":"snapshot","arg":{"instType":"USDT-FUTURES","channel":"ticker","instId":"BTCUSDT"},' \
          '"data":[{"lastPr":"50000.0","ts":"1695716059516"}],"ts":1695716059516}'
      end

      it "Push 型を返し snapshot? / data / ts / 述語が正しく分岐する" do
        result = subject
        expect(result.push?).to be true
        expect(result.event?).to be false
        expect(result.unknown?).to be false
        expect(result.parse_error?).to be false
        expect(result.snapshot?).to be true
        expect(result.update?).to be false
        expect(result.action).to eq("snapshot")
        expect(result.arg).to include("instType" => "USDT-FUTURES", "channel" => "ticker", "instId" => "BTCUSDT")
        expect(result.data).to eq([ { "lastPr" => "50000.0", "ts" => "1695716059516" } ])
        expect(result.ts).to eq(1695716059516)
        expect(result.raw).to eq(raw)
      end
    end

    context "update push の場合" do
      let(:raw) do
        '{"action":"update","arg":{"instType":"USDT-FUTURES","channel":"books","instId":"BTCUSDT"},' \
          '"data":[{"asks":[],"bids":[]}],"ts":1695716059520}'
      end

      it "Push 型を返し update?=true / snapshot?=false となる" do
        result = subject
        expect(result.push?).to be true
        expect(result.update?).to be true
        expect(result.snapshot?).to be false
      end
    end

    context "JSON パース不可の場合" do
      let(:raw) { "not a json" }

      it "ParseError 型を返し raw と error を保持する" do
        result = subject
        expect(result.parse_error?).to be true
        expect(result.event?).to be false
        expect(result.push?).to be false
        expect(result.unknown?).to be false
        expect(result.raw).to eq(raw)
        expect(result.error).to be_a(JSON::ParserError)
      end
    end

    context "event も action も持たない Hash の場合" do
      let(:raw) { '{"foo":"bar"}' }

      it "Unknown 型を返し raw を保持する" do
        result = subject
        expect(result.unknown?).to be true
        expect(result.event?).to be false
        expect(result.push?).to be false
        expect(result.parse_error?).to be false
        expect(result.raw).to eq("foo" => "bar")
      end
    end

    context "JSON が配列(Hash でない)の場合" do
      let(:raw) { '["a","b"]' }

      it "Unknown 型を返す" do
        result = subject
        expect(result.unknown?).to be true
      end
    end
  end
end
