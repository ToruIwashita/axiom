require "rails_helper"

RSpec.describe Infrastructure::ClaudeCodePromptTemplates do
  describe ".render" do
    let(:context) { { trend: "up", rsi: 75 } }

    context "template=entry_filter の場合" do
      subject { described_class.render(template: "entry_filter", context: context) }

      it "context_json プレースホルダが context の JSON 文字列で置換される" do
        result = subject
        expect(result).to include('"trend":"up"')
        expect(result).to include('"rsi":75')
        expect(result).not_to include("{{context_json}}")
      end

      it "template 内容(JSON ONLY 指示等)を含む" do
        expect(subject).to match(/Output JSON ONLY/)
        expect(subject).to match(/"enter": bool/)
      end
    end

    context "template=position_sizing の場合" do
      subject { described_class.render(template: "position_sizing", context: context) }

      it "size_multiplier 0.5-1.5 制約を含む" do
        expect(subject).to match(/0\.5 and 1\.5/)
      end
    end

    context "template=exception_close の場合" do
      subject { described_class.render(template: "exception_close", context: context) }

      it "close 判定指示を含む" do
        expect(subject).to match(/"close": bool/)
      end
    end

    context "template が Symbol で渡された場合" do
      subject { described_class.render(template: :entry_filter, context: context) }

      it "正常に解決される" do
        expect(subject).to include("Output JSON ONLY")
      end
    end

    context "未対応 template が渡された場合" do
      subject { described_class.render(template: "unknown_template", context: context) }

      it "ArgumentError raise" do
        expect { subject }.to raise_error(ArgumentError, /unsupported template/)
      end
    end
  end
end
