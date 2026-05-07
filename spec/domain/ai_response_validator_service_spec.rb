require "rails_helper"

RSpec.describe Domain::AiResponseValidatorService do
  let(:service) { described_class.new }

  describe "#validate" do
    subject do
      service.validate(raw_response: raw_response, context_type: context_type)
    end

    context "context_type=entry_filter の場合" do
      let(:context_type) { "entry_filter" }

      context "正しい JSON{enter: bool, reason: string}の場合" do
        let(:raw_response) { '{"enter": true, "reason": "trend up"}' }

        it "Hash で受理する" do
          expect(subject).to eq({ "enter" => true, "reason" => "trend up" })
        end
      end

      context "enter が false の場合" do
        let(:raw_response) { '{"enter": false, "reason": "weak signal"}' }

        it "Hash で受理する" do
          expect(subject).to include("enter" => false)
        end
      end

      context "enter が boolean でない場合" do
        let(:raw_response) { '{"enter": "true", "reason": "trend up"}' }

        it "nil を返す(型違反)" do
          expect(subject).to be_nil
        end
      end

      context "reason が string でない場合" do
        let(:raw_response) { '{"enter": true, "reason": 123}' }

        it "nil を返す(型違反)" do
          expect(subject).to be_nil
        end
      end

      context "必須キーが欠落している場合" do
        let(:raw_response) { '{"enter": true}' }

        it "nil を返す(reason 欠落)" do
          expect(subject).to be_nil
        end
      end
    end

    context "context_type=position_sizing の場合" do
      let(:context_type) { "position_sizing" }

      context "size_multiplier=1.0(範囲内)の場合" do
        let(:raw_response) { '{"size_multiplier": 1.0}' }

        it "Hash で受理する" do
          expect(subject).to eq({ "size_multiplier" => 1.0 })
        end
      end

      context "size_multiplier=0.5(下限境界)の場合" do
        let(:raw_response) { '{"size_multiplier": 0.5}' }

        it "Hash で受理する" do
          expect(subject).to eq({ "size_multiplier" => 0.5 })
        end
      end

      context "size_multiplier=1.5(上限境界)の場合" do
        let(:raw_response) { '{"size_multiplier": 1.5}' }

        it "Hash で受理する" do
          expect(subject).to eq({ "size_multiplier" => 1.5 })
        end
      end

      context "size_multiplier=0.49(下限超過)の場合" do
        let(:raw_response) { '{"size_multiplier": 0.49}' }

        it "nil を返す" do
          expect(subject).to be_nil
        end
      end

      context "size_multiplier=1.51(上限超過)の場合" do
        let(:raw_response) { '{"size_multiplier": 1.51}' }

        it "nil を返す" do
          expect(subject).to be_nil
        end
      end

      context "size_multiplier が number でない場合" do
        let(:raw_response) { '{"size_multiplier": "1.0"}' }

        it "nil を返す(型違反)" do
          expect(subject).to be_nil
        end
      end
    end

    context "context_type=exception_close の場合" do
      let(:context_type) { "exception_close" }

      context "正しい JSON{close: bool, reason: string}の場合" do
        let(:raw_response) { '{"close": true, "reason": "drawdown alert"}' }

        it "Hash で受理する" do
          expect(subject).to eq({ "close" => true, "reason" => "drawdown alert" })
        end
      end

      context "close が boolean でない場合" do
        let(:raw_response) { '{"close": "true", "reason": "x"}' }

        it "nil を返す" do
          expect(subject).to be_nil
        end
      end
    end

    context "JSON パース失敗時" do
      let(:context_type) { "entry_filter" }
      let(:raw_response) { "not a json" }

      it "nil を返す" do
        expect(subject).to be_nil
      end
    end

    context "未対応 context_type の場合" do
      let(:context_type) { "unknown_type" }
      let(:raw_response) { '{"any": "value"}' }

      it "nil を返す(fail-safe)" do
        expect(subject).to be_nil
      end
    end

    context "Hash を直接渡した場合(JSON.parse 不要)" do
      let(:context_type) { "entry_filter" }
      let(:raw_response) { { "enter" => true, "reason" => "ok" } }

      it "Hash で受理する" do
        expect(subject).to eq({ "enter" => true, "reason" => "ok" })
      end
    end
  end
end
