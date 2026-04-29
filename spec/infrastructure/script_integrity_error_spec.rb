require "rails_helper"

RSpec.describe Infrastructure::ScriptIntegrityError do
  describe "ancestry" do
    subject { described_class }

    context "StandardError 継承を確認する場合" do
      it "StandardError を継承する" do
        expect(subject.ancestors).to include(StandardError)
      end
    end
  end

  describe "#message" do
    subject { described_class.new(message).message }

    context "メッセージを渡してインスタンス化した場合" do
      let(:message) { "checksum mismatch" }

      it "渡したメッセージを保持する" do
        expect(subject).to eq("checksum mismatch")
      end
    end
  end
end
