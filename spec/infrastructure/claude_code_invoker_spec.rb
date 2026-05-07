require "rails_helper"

RSpec.describe Infrastructure::ClaudeCodeInvoker do
  let(:logger) { instance_double(Logger, warn: nil, info: nil, error: nil, debug: nil) }
  let(:invoker) { described_class.new(executor: executor, logger: logger) }
  let(:stdin) { instance_double(IO, write: nil, close: nil) }
  let(:stdout) { instance_double(IO, read: stdout_content) }
  let(:stderr) { instance_double(IO) }
  let(:wait_thread) { instance_double(Thread, value: process_status, kill: nil) }
  let(:process_status) { instance_double(Process::Status, success?: success) }
  let(:executor) { instance_double(Method) }

  describe "#invoke" do
    subject { invoker.invoke(prompt: "test prompt", timeout_sec: 5.0) }

    context "CLI が正常に成功した場合" do
      let(:stdout_content) { '{"enter": true, "reason": "ok"}' }
      let(:success) { true }

      before do
        allow(executor).to receive(:call) do |*_args, &_block|
          [ stdin, stdout, stderr, wait_thread ]
        end
      end

      it "stdout の文字列を返す" do
        expect(subject).to eq('{"enter": true, "reason": "ok"}')
      end

      it "stdin に prompt を書き込み close する" do
        subject
        expect(stdin).to have_received(:write).with("test prompt")
        expect(stdin).to have_received(:close)
      end
    end

    context "CLI が異常終了した場合(success? = false)" do
      let(:stdout_content) { "" }
      let(:success) { false }

      before do
        allow(executor).to receive(:call).and_return([ stdin, stdout, stderr, wait_thread ])
        allow(stderr).to receive(:read).and_return("error output")
      end

      it "nil を返す" do
        expect(subject).to be_nil
      end

      it "logger.warn でエラー記録" do
        subject
        expect(logger).to have_received(:warn).with(/ClaudeCodeInvoker.*non-zero exit/)
      end
    end

    context "Timeout 発生時" do
      before do
        allow(executor).to receive(:call) do |*_args|
          # Timeout.timeout でブロック中に発生したように振る舞う
          raise Timeout::Error
        end
      end

      it "nil を返す" do
        expect(subject).to be_nil
      end

      it "logger.warn でタイムアウト記録" do
        subject
        expect(logger).to have_received(:warn).with(/ClaudeCodeInvoker.*timeout/)
      end
    end

    context "executor が StandardError を raise した場合(CLI 不在等)" do
      before do
        allow(executor).to receive(:call).and_raise(Errno::ENOENT, "claude command not found")
      end

      it "nil を返す" do
        expect(subject).to be_nil
      end

      it "logger.warn でエラー記録" do
        subject
        expect(logger).to have_received(:warn).with(/ClaudeCodeInvoker.*error/)
      end
    end
  end

  describe "#cli_available?" do
    let(:status) { instance_double(Process::Status, success?: success) }

    context "claude --version が成功する場合" do
      let(:success) { true }

      before do
        allow(executor).to receive(:call).with("claude", "--version").and_return([
          double(close: nil), double(read: "claude 1.0.0"), double(read: ""), double(value: status)
        ])
      end

      it "true を返す" do
        expect(invoker.cli_available?).to be true
      end
    end

    context "claude --version が失敗する場合" do
      let(:success) { false }

      before do
        allow(executor).to receive(:call).with("claude", "--version").and_return([
          double(close: nil), double(read: ""), double(read: ""), double(value: status)
        ])
      end

      it "false を返す" do
        expect(invoker.cli_available?).to be false
      end
    end

    context "Errno::ENOENT が raise された場合(CLI 不在)" do
      before do
        allow(executor).to receive(:call).with("claude", "--version")
          .and_raise(Errno::ENOENT, "claude not found")
      end

      it "false を返す" do
        expect(invoker.cli_available?).to be false
      end
    end
  end
end
