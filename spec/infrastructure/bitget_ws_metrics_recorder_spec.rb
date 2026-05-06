require "rails_helper"

RSpec.describe Infrastructure::BitgetWsMetricsRecorder do
  let(:current_time) { [ Time.utc(2026, 5, 6, 12, 0, 0) ] }
  let(:clock) { -> { current_time[0] } }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }
  let(:threshold_count) { 3 }
  let(:window_seconds) { 60 }
  let(:recorder) do
    described_class.new(
      clock: clock,
      logger: logger,
      threshold_count: threshold_count,
      window_seconds: window_seconds
    )
  end

  describe "#record_failure" do
    context "閾値未満の失敗の場合" do
      it "logger.error は呼ばれない" do
        2.times { recorder.record_failure }
        expect(logger).not_to have_received(:error)
      end
    end

    context "window 内で閾値に達した場合" do
      it "logger.error でアラート出力" do
        threshold_count.times { recorder.record_failure }
        expect(logger).to have_received(:error).with(/repeated reconnect failures/).at_least(:once)
      end
    end

    context "window 外の古い失敗は閾値計算から除外される" do
      it "古い失敗 + 直近 (threshold-1) 件は閾値未満扱い(アラートなし)" do
        # 古い失敗(window 外)
        (threshold_count - 1).times { recorder.record_failure }
        # window を超えて時刻を進める
        current_time[0] = current_time[0] + (window_seconds + 1)
        # window 内に閾値未満
        (threshold_count - 1).times { recorder.record_failure }
        expect(logger).not_to have_received(:error)
      end
    end
  end

  describe "#record_success" do
    it "失敗カウントをリセットする(連続失敗判定の打ち切り)" do
      (threshold_count - 1).times { recorder.record_failure }
      recorder.record_success
      (threshold_count - 1).times { recorder.record_failure }
      expect(logger).not_to have_received(:error)
    end
  end

  describe "#failure_count_in_window" do
    it "現在の window 内の失敗件数を返す" do
      recorder.record_failure
      recorder.record_failure
      expect(recorder.failure_count_in_window).to eq(2)
    end

    it "window 外の失敗は含めない" do
      recorder.record_failure
      current_time[0] = current_time[0] + (window_seconds + 1)
      expect(recorder.failure_count_in_window).to eq(0)
    end
  end
end
