require "rails_helper"

RSpec.describe Domain::CandleConfirmDetector do
  let(:detector) { described_class.new }

  # Bitget candle row: [ts(ms), open, high, low, close, base_volume, quote_volume]
  let(:row1) { [ "1700000000000", "50000", "50100", "49900", "50050", "1.0", "50050.0" ] }
  let(:row2) { [ "1700000060000", "50050", "50200", "50000", "50150", "2.0", "100200.0" ] }

  describe "#observe(row) → confirmed_payload | nil" do
    context "初回 observe(prev nil)" do
      it "nil を返す(確定なし)" do
        expect(detector.observe(row1)).to be_nil
      end
    end

    context "同 ts の row が連続" do
      it "nil を返す(同 candle 更新中)" do
        detector.observe(row1)
        expect(detector.observe(row1)).to be_nil
      end
    end

    context "新 ts の row 受信" do
      it "直前 row を確定 payload として返す(ts/open/high/low/close/base_volume/quote_volume)" do
        detector.observe(row1)
        payload = detector.observe(row2)
        expect(payload).to eq(
          "ts" => 1_700_000_000_000,
          "open" => "50000",
          "high" => "50100",
          "low" => "49900",
          "close" => "50050",
          "base_volume" => "1.0",
          "quote_volume" => "50050.0"
        )
      end
    end
  end

  describe "#snapshot_init(row) → row を保持するのみ(確定判定なし)" do
    it "snapshot 末尾 row を保持し,以降の observe で確定判定の起点に使われる" do
      detector.snapshot_init(row1)
      payload = detector.observe(row2)
      expect(payload).not_to be_nil
      expect(payload["ts"]).to eq(1_700_000_000_000)
    end
  end

  describe "#reset → 保持 row をクリア" do
    it "reset 後の observe は nil(prev nil 状態に戻る)" do
      detector.observe(row1)
      detector.reset
      expect(detector.observe(row2)).to be_nil
    end
  end

  describe "thread-safety" do
    # 複数 thread から observe / reset / snapshot_init を交錯させても torn read が起きないことを検証.
    it "並列 observe / reset 中に raise しない / 戻り値が常に Hash か nil" do
      writer_count = 8
      iterations = 50
      observed = Queue.new

      writers = writer_count.times.map do |i|
        Thread.new do
          iterations.times do |j|
            ts_ms = ((i * iterations) + j) * 1000
            row = [ ts_ms.to_s, "50000", "50100", "49900", "50050", "1.0", "50050.0" ]
            observed << detector.observe(row)
          end
        end
      end

      resetter = Thread.new do
        iterations.times do
          detector.reset
        end
      end

      (writers + [ resetter ]).each(&:join)

      observed.size.times do
        result = observed.pop
        expect(result).to be_nil.or(be_a(Hash))
      end
    end
  end
end
