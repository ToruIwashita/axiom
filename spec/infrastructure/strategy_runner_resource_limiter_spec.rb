require "rails_helper"

RSpec.describe Infrastructure::StrategyRunnerResourceLimiter do
  let(:limiter) { described_class.new }

  describe "#apply_limits!" do
    subject { limiter.apply_limits! }

    before do
      allow(Process).to receive(:setrlimit)
    end

    context "通常環境(RLIMIT_AS 利用可能)の場合" do
      it "Process.setrlimit(RLIMIT_CPU, 1) と RLIMIT_AS=256MB を呼ぶ" do
        subject
        expect(Process).to have_received(:setrlimit).with(Process::RLIMIT_CPU, 1)
        expect(Process).to have_received(:setrlimit).with(Process::RLIMIT_AS, 256 * 1024 * 1024)
      end
    end
  end

  describe "#minimal_env" do
    subject { limiter.minimal_env }

    context "ENV に PATH / LANG / その他キーが存在する場合" do
      before do
        allow(ENV).to receive(:to_h).and_return(
          "PATH" => "/usr/bin",
          "LANG" => "ja_JP.UTF-8",
          "FOO" => "bar",
          "SECRET_KEY" => "abc"
        )
      end

      it "PATH / LANG のみを含む Hash を返す" do
        expect(subject).to eq("PATH" => "/usr/bin", "LANG" => "ja_JP.UTF-8")
      end
    end

    context "ENV に PATH のみが存在する場合" do
      before do
        allow(ENV).to receive(:to_h).and_return("PATH" => "/usr/bin")
      end

      it "PATH のみを含む Hash を返す" do
        expect(subject).to eq("PATH" => "/usr/bin")
      end
    end
  end
end
