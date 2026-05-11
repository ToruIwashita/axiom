require "rails_helper"

RSpec.describe Domain::AnomalyReconcileDebouncer do
  let(:clock_value) { [ 1000.0 ] } # 可変参照で時刻 mock
  let(:monotonic_clock) { -> { clock_value.first } }
  let(:debounce_seconds) { 30 }
  let(:debouncer) do
    described_class.new(monotonic_clock: monotonic_clock, debounce_seconds: debounce_seconds)
  end

  describe "#try_acquire" do
    context "初回呼出" do
      it "true を返す(取得成功)" do
        expect(debouncer.try_acquire).to be true
      end
    end

    context "既に in-progress の場合" do
      before { debouncer.try_acquire }

      it "false を返す(取得失敗 / 重複起動防止)" do
        expect(debouncer.try_acquire).to be false
      end
    end

    context "release 後 debounce_seconds 未満の経過時間" do
      before do
        debouncer.try_acquire
        debouncer.release
        clock_value[0] = 1010.0 # 10s 経過(< 30s)
      end

      it "false を返す(debounce 中)" do
        expect(debouncer.try_acquire).to be false
      end
    end

    context "release 後 debounce_seconds 経過済" do
      before do
        debouncer.try_acquire
        debouncer.release
        clock_value[0] = 1031.0 # 31s 経過(>= 30s)
      end

      it "true を返す(再取得成功)" do
        expect(debouncer.try_acquire).to be true
      end
    end

    context "release 後 debounce_seconds 境界(ちょうど 30s)" do
      before do
        debouncer.try_acquire
        debouncer.release
        clock_value[0] = 1030.0 # ちょうど 30s 経過
      end

      # 実装の判定は `(now - last) < debounce_seconds` で `<` 比較.
      # `30 < 30` → false → 取得許可 → `true` 返却.
      it "true を返す(`now - last < debounce` が false → 取得許可)" do
        expect(debouncer.try_acquire).to be true
      end
    end
  end

  describe "#release" do
    it "in-progress フラグを解除し,debounce_seconds 経過後の try_acquire を許可する" do
      debouncer.try_acquire
      debouncer.release
      clock_value[0] = 1100.0 # 100s 経過
      expect(debouncer.try_acquire).to be true
    end

    it "release のみでは debounce_seconds 内の再取得は許可しない" do
      debouncer.try_acquire
      debouncer.release
      # clock 進んでいない(0s 経過)
      expect(debouncer.try_acquire).to be false
    end
  end

  describe "thread-safety" do
    # 複数 thread で try_acquire を同時呼出し,1 thread のみ true を取れることを検証.
    it "100 thread が同時に try_acquire しても 1 thread のみ取得成功" do
      debouncer = described_class.new(monotonic_clock: -> { 1000.0 }, debounce_seconds: 30)
      results = Queue.new
      threads = 100.times.map { Thread.new { results << debouncer.try_acquire } }
      threads.each(&:join)

      acquired_count = 0
      results.size.times { acquired_count += 1 if results.pop }
      expect(acquired_count).to eq(1)
    end
  end
end
