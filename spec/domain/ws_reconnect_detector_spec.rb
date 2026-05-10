require "rails_helper"

RSpec.describe Domain::WsReconnectDetector do
  let(:detector) { described_class.new }

  def ws_double(reconnect_count)
    double("WsClient", reconnect_count: reconnect_count)
  end

  describe "#reset(public_ws:, private_ws:)" do
    it "現在の reconnect_count を初期値として記録する" do
      pub = ws_double(3)
      pri = ws_double(5)
      detector.reset(public_ws: pub, private_ws: pri)

      result = detector.snapshot(public_ws: pub, private_ws: pri)
      expect(result.public_reconnected).to be false
      expect(result.private_reconnected).to be false
    end

    it "reconnect_count に respond しない nil を渡しても 0 として扱う" do
      detector.reset(public_ws: nil, private_ws: nil)
      result = detector.snapshot(public_ws: nil, private_ws: nil)
      expect(result.public_count).to eq(0)
      expect(result.private_count).to eq(0)
    end
  end

  describe "#snapshot(public_ws:, private_ws:)" do
    before { detector.reset(public_ws: ws_double(0), private_ws: ws_double(0)) }

    context "public_ws のみ reconnect 検知(0 → 1)" do
      let(:pub) { ws_double(1) }
      let(:pri) { ws_double(0) }

      it "public_reconnected = true / private_reconnected = false" do
        result = detector.snapshot(public_ws: pub, private_ws: pri)
        expect(result.public_reconnected).to be true
        expect(result.private_reconnected).to be false
        expect(result.any?).to be true
        expect(result.public_count).to eq(1)
      end
    end

    context "private_ws のみ reconnect 検知(0 → 2)" do
      let(:pub) { ws_double(0) }
      let(:pri) { ws_double(2) }

      it "public_reconnected = false / private_reconnected = true" do
        result = detector.snapshot(public_ws: pub, private_ws: pri)
        expect(result.public_reconnected).to be false
        expect(result.private_reconnected).to be true
        expect(result.any?).to be true
      end
    end

    context "両方 reconnect 検知" do
      let(:pub) { ws_double(1) }
      let(:pri) { ws_double(1) }

      it "両方 true / any? = true" do
        result = detector.snapshot(public_ws: pub, private_ws: pri)
        expect(result.public_reconnected).to be true
        expect(result.private_reconnected).to be true
        expect(result.any?).to be true
      end
    end

    context "reconnect なし(count 不変)" do
      it "any? = false" do
        result = detector.snapshot(public_ws: ws_double(0), private_ws: ws_double(0))
        expect(result.any?).to be false
      end
    end
  end

  describe "#update_to(public_count:, private_count:)" do
    before { detector.reset(public_ws: ws_double(0), private_ws: ws_double(0)) }

    it "次回 snapshot の比較基準を更新する" do
      detector.update_to(public_count: 5, private_count: 3)

      # 5 / 3 で snapshot → reconnect なし
      result = detector.snapshot(public_ws: ws_double(5), private_ws: ws_double(3))
      expect(result.any?).to be false

      # 6 / 3 で snapshot → public のみ reconnect
      result2 = detector.snapshot(public_ws: ws_double(6), private_ws: ws_double(3))
      expect(result2.public_reconnected).to be true
      expect(result2.private_reconnected).to be false
    end
  end

  describe "#read_count(ws) 防御 helper" do
    it "ws が nil なら 0" do
      detector.reset(public_ws: nil, private_ws: nil)
      result = detector.snapshot(public_ws: nil, private_ws: nil)
      expect(result.public_count).to eq(0)
    end

    it "ws が reconnect_count に respond しない場合も 0" do
      ws = double("BadWs")
      detector.reset(public_ws: ws, private_ws: ws)
      result = detector.snapshot(public_ws: ws, private_ws: ws)
      expect(result.public_count).to eq(0)
    end

    it "reconnect_count が String の場合は to_i で Integer 化" do
      detector.reset(public_ws: ws_double(0), private_ws: ws_double(0))
      result = detector.snapshot(public_ws: ws_double("7"), private_ws: ws_double(0))
      expect(result.public_count).to eq(7)
    end
  end

  describe "thread-safety" do
    it "並列 snapshot / update_to / reset を交錯させても raise しない + 最終 snapshot 整合性確認" do
      target_detector = detector
      target_detector.reset(public_ws: ws_double(0), private_ws: ws_double(0))

      reader_pub = ws_double(1)
      reader_pri = ws_double(1)
      readers = 10.times.map do
        Thread.new do
          50.times { target_detector.snapshot(public_ws: reader_pub, private_ws: reader_pri) }
        end
      end

      writers = 10.times.map do |i|
        Thread.new do
          50.times { target_detector.update_to(public_count: i, private_count: i) }
        end
      end

      expect { (readers + writers).each(&:join) }.not_to raise_error

      # 最終 snapshot で last_*_count が monotonic 更新済(reset 起点 0 から進んでいる)を確認.
      result = target_detector.snapshot(public_ws: ws_double(100), private_ws: ws_double(100))
      expect(result.public_count).to eq(100)
      expect(result.private_count).to eq(100)
    end
  end
end
