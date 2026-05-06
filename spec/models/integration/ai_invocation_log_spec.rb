require "rails_helper"

RSpec.describe Integration::AiInvocationLog, type: :model do
  let(:base_attributes) do
    {
      context_type: "entry_filter",
      prompt: "test prompt",
      response: "{\"enter\": true}",
      latency_ms: 1234,
      status: "success"
    }
  end

  describe "validations" do
    subject { described_class.new(attributes) }

    context "必須属性が全て揃っている場合" do
      let(:attributes) { base_attributes }

      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end

    %i[context_type latency_ms status].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { base_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end

    context "latency_ms が負の場合" do
      let(:attributes) { base_attributes.merge(latency_ms: -1) }

      it "valid? が false を返す" do
        expect(subject).not_to be_valid
        expect(subject.errors[:latency_ms]).to be_present
      end
    end
  end

  describe "enums" do
    subject { described_class.new(base_attributes) }

    context "context_type enum が 7 値定義されている" do
      it "script_generation/backtest_analysis/strategy_improvement/entry_filter/position_sizing/exception_close/daily_review を全て受理する" do
        %w[
          script_generation backtest_analysis strategy_improvement
          entry_filter position_sizing exception_close daily_review
        ].each do |t|
          subject.context_type = t
          expect(subject.context_type).to eq(t)
        end
      end

      it "未定義の context_type は ArgumentError" do
        expect { subject.context_type = "unknown" }.to raise_error(ArgumentError)
      end
    end

    context "status enum が 4 値定義されている" do
      it "success/timeout/error/validation_failed を全て受理する" do
        %w[success timeout error validation_failed].each do |s|
          subject.status = s
          expect(subject.status).to eq(s)
        end
      end

      it "未定義の status は ArgumentError" do
        expect { subject.status = "unknown" }.to raise_error(ArgumentError)
      end
    end
  end

  describe "prompt / response の 10_000 文字 truncate(レビュー軽微 3 反映: 必須化)" do
    let(:long_text) { "x" * 11_000 }

    context "prompt が 10_000 文字を超える場合" do
      let(:attributes) { base_attributes.merge(prompt: long_text) }
      let(:log) { described_class.create!(attributes) }

      it "before_validation で 10_000 文字に truncate される" do
        expect(log.prompt.length).to eq(10_000)
      end
    end

    context "response が 10_000 文字を超える場合" do
      let(:attributes) { base_attributes.merge(response: long_text) }
      let(:log) { described_class.create!(attributes) }

      it "before_validation で 10_000 文字に truncate される" do
        expect(log.response.length).to eq(10_000)
      end
    end

    # Phase 3.1 レビュー R-10 反映: 境界値の片側欠落補完(9_999 / 10_000 / 10_001 文字)
    # ActiveSupport の String#truncate(N) は N 文字以下なら無変更,N+1 以上なら N 文字に truncate
    context "prompt が 9_999 文字の場合(境界 - 1)" do
      let(:attributes) { base_attributes.merge(prompt: "x" * 9_999) }
      let(:log) { described_class.create!(attributes) }

      it "truncate されず 9_999 文字のまま" do
        expect(log.prompt.length).to eq(9_999)
      end
    end

    context "prompt が 10_000 文字ちょうどの場合(境界値)" do
      let(:attributes) { base_attributes.merge(prompt: "x" * 10_000) }
      let(:log) { described_class.create!(attributes) }

      it "truncate されず 10_000 文字のまま" do
        expect(log.prompt.length).to eq(10_000)
      end
    end

    context "prompt が 10_001 文字の場合(境界 + 1)" do
      let(:attributes) { base_attributes.merge(prompt: "x" * 10_001) }
      let(:log) { described_class.create!(attributes) }

      it "10_000 文字に truncate される" do
        expect(log.prompt.length).to eq(10_000)
      end
    end

    context "prompt / response が nil の場合" do
      let(:attributes) { base_attributes.merge(prompt: nil, response: nil) }
      let(:log) { described_class.new(attributes) }

      it "truncate 処理で例外が発生しない" do
        expect { log.valid? }.not_to raise_error
        expect(log.prompt).to be_nil
        expect(log.response).to be_nil
      end
    end
  end

  describe ".record!" do
    let(:context_type) { "entry_filter" }
    let(:prompt) { "test prompt" }
    let(:response) { "{\"enter\": true}" }
    let(:latency_ms) { 1234 }
    let(:status) { "success" }

    subject do
      described_class.record!(
        context_type: context_type,
        prompt: prompt,
        response: response,
        latency_ms: latency_ms,
        status: status
      )
    end

    it "AiInvocationLog レコードを作成する" do
      expect { subject }.to change(described_class, :count).by(1)
      result = described_class.last
      expect(result.context_type).to eq(context_type)
      expect(result.prompt).to eq(prompt)
      expect(result.response).to eq(response)
      expect(result.latency_ms).to eq(latency_ms)
      expect(result.status).to eq(status)
    end
  end
end
