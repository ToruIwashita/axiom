require "rails_helper"

RSpec.describe Domain::BackgroundThreadRegistry do
  let(:logger) { instance_double(Logger, error: nil, warn: nil, info: nil, debug: nil) }
  let(:clock_value) { [ 1000.0 ] }
  let(:monotonic_clock) { -> { clock_value.first } }
  let(:registry) do
    described_class.new(
      monotonic_clock: monotonic_clock,
      logger: logger,
      sweep_interval_seconds: 60,
      join_timeout_seconds: 1.0
    )
  end

  describe "#spawn(label) { ... }" do
    it "新規 Thread を起動し,Thread を返却する" do
      thread = registry.spawn("task") { "done" }
      expect(thread).to be_a(Thread)
      thread.join
    end

    it "spawn した Thread が registry 内部に保持される(size = 1)" do
      thread = registry.spawn("task") { sleep 0.05 }
      expect(registry.size).to eq(1)
      thread.join
    end

    it "block 内例外を rescue + logger.error 落とし(thread を止めない)" do
      thread = registry.spawn("failing_task") { raise StandardError, "boom" }
      thread.join
      expect(logger).to have_received(:error)
        .with(/background task 'failing_task' failed.*StandardError.*boom/)
    end

    it "AR connection_pool.with_connection で wrap される(connection 確保)" do
      pool = ActiveRecord::Base.connection_pool
      expect(pool).to receive(:with_connection).and_call_original

      thread = registry.spawn("task") { :ok }
      thread.join
    end

    it "block 内例外メッセージは sanitize される(機微情報遮断)" do
      thread = registry.spawn("task") { raise StandardError, "Faraday error: api_key=ABC123 failed" }
      thread.join
      expect(logger).to have_received(:error).with(/api_key=\[FILTERED\]/)
    end
  end

  describe "#sweep_if_due" do
    it "初回呼出は sweep 実行(完了済 thread 除去 + 最終 sweep 時刻を更新)" do
      finished = registry.spawn("task") { :ok }
      finished.join
      registry.sweep_if_due
      expect(registry.size).to eq(0)
    end

    it "sweep_interval_seconds 未満の経過では sweep スキップ" do
      finished = registry.spawn("task") { :ok }
      finished.join
      registry.sweep_if_due # 初回 sweep
      registry.spawn("alive") { sleep 0.5 } # alive thread 追加
      clock_value[0] = 1010.0 # 10s 経過(< 60s)
      registry.sweep_if_due
      expect(registry.size).to eq(1) # alive thread が残る
    end

    it "sweep_interval_seconds 以上経過後の sweep で完了済み thread が除去される" do
      finished = registry.spawn("task") { :ok }
      finished.join
      registry.sweep_if_due # 初回 sweep
      finished2 = registry.spawn("task2") { :ok }
      finished2.join
      clock_value[0] = 1061.0 # 61s 経過(>= 60s)
      registry.sweep_if_due
      expect(registry.size).to eq(0)
    end
  end

  describe "#join_all" do
    it "全 thread を timeout 付きで join + 配列 clear" do
      registry.spawn("fast1") { :ok }
      registry.spawn("fast2") { :ok }
      registry.join_all
      expect(registry.size).to eq(0)
    end

    it "timeout 超過時は thread.kill + logger.warn" do
      registry.spawn("slow") { sleep 5 } # join_timeout (1.0s) より長い
      registry.join_all
      expect(logger).to have_received(:warn)
        .with(/background thread did not finish within 1\.0s.*killing/)
      expect(registry.size).to eq(0)
    end

    it "thread が空の場合は no-op(kill / warn 呼ばない)" do
      registry.join_all
      expect(logger).not_to have_received(:warn)
    end
  end

  describe "thread-safety" do
    # 並列 spawn / sweep / join_all を交錯させ raise しないことを検証.
    it "並列 spawn 中に sweep_if_due が走っても整合性維持" do
      writers = 10.times.map do
        Thread.new do
          5.times { registry.spawn("task") { :ok } }
        end
      end
      sweeper = Thread.new do
        10.times { registry.sweep_if_due; sleep 0.001 }
      end
      (writers + [ sweeper ]).each(&:join)
      registry.join_all
      expect(registry.size).to eq(0)
    end
  end
end
