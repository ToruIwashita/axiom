require "rails_helper"

RSpec.describe Infrastructure::BitgetPrivateWsMessageDecoder do
  describe ".decode" do
    subject { described_class.decode(raw) }

    context "login レスポンスを受信した場合" do
      let(:raw) { '{"event":"login","code":0,"msg":""}' }

      it "Event 型(login_success)で event_name=login / code=0 を返す" do
        result = subject
        expect(result).to be_event
        expect(result).not_to be_push
        expect(result.event_name).to eq("login")
        expect(result.code).to eq(0)
        expect(result).to be_login_success
      end
    end

    context "login 失敗レスポンスを受信した場合" do
      let(:raw) { '{"event":"login","code":30005,"msg":"signature error"}' }

      it "Event 型で login_success? が false / error? が true" do
        result = subject
        expect(result).to be_event
        expect(result).not_to be_login_success
        expect(result).to be_error
        expect(result.code).to eq(30005)
        expect(result.message).to eq("signature error")
      end
    end

    context "subscribe イベントを受信した場合" do
      let(:raw) do
        '{"event":"subscribe","arg":{"instType":"USDT-FUTURES","channel":"orders","instId":"default"}}'
      end

      it "Event 型で event_name=subscribe を返す" do
        result = subject
        expect(result).to be_event
        expect(result.event_name).to eq("subscribe")
      end
    end

    context "orders push を受信した場合" do
      let(:raw) do
        <<~JSON
          {
            "action":"snapshot",
            "arg":{"instType":"USDT-FUTURES","channel":"orders","instId":"default"},
            "data":[{"orderId":"12345","status":"new"}],
            "ts":1695716059516
          }
        JSON
      end

      it "Push 型で channel 述語 orders? が true / orders_algo? は false" do
        result = subject
        expect(result).to be_push
        expect(result).to be_orders
        expect(result).not_to be_orders_algo
        expect(result).not_to be_fill
        expect(result.data).to eq([ { "orderId" => "12345", "status" => "new" } ])
      end
    end

    context "orders-algo push を受信した場合" do
      let(:raw) do
        <<~JSON
          {
            "action":"snapshot",
            "arg":{"instType":"USDT-FUTURES","channel":"orders-algo","instId":"default"},
            "data":[{"algoId":"a-1","state":"live"}],
            "ts":1695716059516
          }
        JSON
      end

      it "Push 型で orders_algo? が true" do
        result = subject
        expect(result).to be_push
        expect(result).to be_orders_algo
        expect(result).not_to be_orders
      end
    end

    context "fill push を受信した場合" do
      let(:raw) do
        <<~JSON
          {
            "action":"update",
            "arg":{"instType":"USDT-FUTURES","channel":"fill","instId":"default"},
            "data":[{"fillId":"f-1","price":"50000"}],
            "ts":1695716059516
          }
        JSON
      end

      it "Push 型で fill? が true" do
        result = subject
        expect(result).to be_push
        expect(result).to be_fill
        expect(result).to be_update
      end
    end

    context "positions push を受信した場合" do
      let(:raw) do
        <<~JSON
          {
            "action":"snapshot",
            "arg":{"instType":"USDT-FUTURES","channel":"positions","instId":"default"},
            "data":[{"symbol":"BTCUSDT","total":"0.01","frozen":"0"}],
            "ts":1695716059516
          }
        JSON
      end

      it "Push 型で positions? が true" do
        result = subject
        expect(result).to be_push
        expect(result).to be_positions
        expect(result).to be_snapshot
      end
    end

    context "positions-history push を受信した場合" do
      let(:raw) do
        <<~JSON
          {
            "action":"snapshot",
            "arg":{"instType":"USDT-FUTURES","channel":"positions-history","instId":"default"},
            "data":[{"symbol":"BTCUSDT","closedAt":"123"}],
            "ts":1695716059516
          }
        JSON
      end

      it "Push 型で positions_history? が true / positions? は false" do
        result = subject
        expect(result).to be_push
        expect(result).to be_positions_history
        expect(result).not_to be_positions
      end
    end

    context "account push を受信した場合" do
      let(:raw) do
        <<~JSON
          {
            "action":"snapshot",
            "arg":{"instType":"USDT-FUTURES","channel":"account","instId":"default"},
            "data":[{"marginCoin":"USDT","available":"1000"}],
            "ts":1695716059516
          }
        JSON
      end

      it "Push 型で account? が true" do
        result = subject
        expect(result).to be_push
        expect(result).to be_account
      end
    end

    context "JSON パースエラー" do
      let(:raw) { "not a json" }

      it "ParseError 型で raw / error を保持する" do
        result = subject
        expect(result).to be_parse_error
        expect(result.raw).to eq("not a json")
        expect(result.error).to be_a(JSON::ParserError)
      end
    end

    context "event / action どちらも持たない構造の場合" do
      let(:raw) { '{"unexpected":"value"}' }

      it "Unknown 型を返す" do
        result = subject
        expect(result).to be_unknown
      end
    end
  end

  describe "orders-algo の状態別述語(algo_create? / algo_triggered? / algo_cancelled? / algo_anomaly?)" do
    let(:raw) do
      <<~JSON
        {
          "action":"snapshot",
          "arg":{"instType":"USDT-FUTURES","channel":"orders-algo","instId":"default"},
          "data":[{"algoId":"a-1","state":"#{state}"}],
          "ts":1695716059516
        }
      JSON
    end

    subject { described_class.decode(raw) }

    context "state=live(発注成功)の場合" do
      let(:state) { "live" }

      it "algo_create? が true で他は false" do
        result = subject
        expect(result).to be_algo_create
        expect(result).not_to be_algo_triggered
        expect(result).not_to be_algo_cancelled
        expect(result).not_to be_algo_anomaly
      end
    end

    context "state=executed(トリガー到達)の場合" do
      let(:state) { "executed" }

      it "algo_triggered? が true" do
        result = subject
        expect(result).to be_algo_triggered
      end
    end

    context "state=canceled の場合" do
      let(:state) { "canceled" }

      it "algo_cancelled? が true" do
        result = subject
        expect(result).to be_algo_cancelled
      end
    end

    context "state=未知値の場合" do
      let(:state) { "weird_state_xyz" }

      it "algo_anomaly? が true(未知状態は anomaly 扱い)" do
        result = subject
        expect(result).to be_algo_anomaly
      end
    end
  end
end
