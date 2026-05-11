require "rails_helper"

RSpec.describe Domain::CandleConfirmDetector do
  let(:detector) { described_class.new }
  # Bitget candle row: [ts(ms), open, high, low, close, base_volume, quote_volume]
  let(:row1) { [ "1700000000000", "50000", "50100", "49900", "50050", "1.0", "50050.0" ] }
  let(:row2) { [ "1700000060000", "50050", "50200", "50000", "50150", "2.0", "100200.0" ] }

  describe "#observe" do
    subject { detector.observe(observed_row) }

    context "初回 observe(prev nil)" do
      let(:observed_row) { row1 }
      it { is_expected.to be_nil }
    end

    context "同 ts の row が連続" do
      let(:observed_row) { row1 }
      before { detector.observe(row1) }
      it { is_expected.to be_nil }
    end

    context "新 ts の row 受信(prev 確定)" do
      let(:observed_row) { row2 }
      before { detector.observe(row1) }

      it "直前 row を確定 payload(ts/open/high/low/close/base_volume/quote_volume)として返す" do
        expect(subject).to eq(
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

  describe "#snapshot_init" do
    subject { detector.snapshot_init(row1) }

    it "末尾 row を保持し,以降の observe で確定判定の起点に使われる" do
      subject
      payload = detector.observe(row2)
      expect(payload["ts"]).to eq(1_700_000_000_000)
    end
  end

  describe "#reset" do
    subject { detector.reset }

    it "保持 row をクリアし,reset 後初回の observe は nil" do
      detector.observe(row1)
      subject
      expect(detector.observe(row2)).to be_nil
    end
  end

  describe "thread-safety" do
    # writer 8 thread × 50 反復 + resetter 1 thread を交錯し,
    # (1) raise しない / 戻り値型が Hash or nil(2) 確定 payload の ts 単調性 を検証.
    # RSpec の let は thread-safe ではないため detector を local 変数にキャプチャしてから spawn する.
    subject do
      target_detector = detector
      writer_count = 8
      iterations = 50
      observed = Queue.new
      writers = writer_count.times.map do |i|
        Thread.new do
          iterations.times do |j|
            ts_ms = ((i * iterations) + j) * 1000
            row = [ ts_ms.to_s, "50000", "50100", "49900", "50050", "1.0", "50050.0" ]
            observed << target_detector.observe(row)
          end
        end
      end
      resetter = Thread.new { iterations.times { target_detector.reset } }
      (writers + [ resetter ]).each(&:join)

      collected = []
      collected << observed.pop until observed.empty?
      collected
    end

    it "全 observe 戻り値が Hash か nil / 確定 payload の ts は writer 上限以下" do
      results = subject
      hashes = results.compact
      expect(results - hashes).to all(be_nil)
      expect(hashes).to all(be_a(Hash))
      max_ts = (8 * 50 - 1) * 1000
      expect(hashes.map { |h| h["ts"] }).to all(be <= max_ts)
    end
  end
end
