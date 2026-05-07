require "rails_helper"

RSpec.describe Domain::AiFilterService do
  let(:invoker) { instance_double(Infrastructure::ClaudeCodeInvoker) }
  let(:validator) { instance_double(Domain::AiResponseValidatorService) }
  let(:template_repository) { instance_double("TemplateRepository") }
  let(:log_recorder) { class_double(Integration::AiInvocationLog) }
  let(:current_time) { [ Time.utc(2026, 5, 7, 12, 0, 0) ] }
  let(:clock) { -> { current_time[0] } }
  let(:service) do
    described_class.new(
      invoker: invoker,
      validator: validator,
      template_repository: template_repository,
      log_recorder: log_recorder,
      clock: clock
    )
  end

  describe "#call" do
    let(:template) { :entry_filter }
    let(:context) { { trend: "up" } }
    let(:context_type) { "entry_filter" }
    let(:rendered_prompt) { "rendered: trend=up" }

    before do
      allow(template_repository).to receive(:render)
        .with(template: template, context: context)
        .and_return(rendered_prompt)
      allow(log_recorder).to receive(:record!)
    end

    subject do
      service.call(
        template: template,
        context: context,
        context_type: context_type,
        timeout_sec: 5.0,
        fail_safe: fail_safe
      )
    end

    context "Invoker 成功 + Validator 通過の場合" do
      let(:fail_safe) { "skip" }
      let(:raw) { '{"enter": true, "reason": "ok"}' }
      let(:validated) { { "enter" => true, "reason" => "ok" } }

      before do
        allow(invoker).to receive(:invoke)
          .with(prompt: rendered_prompt, timeout_sec: 5.0)
          .and_return(raw)
        allow(validator).to receive(:validate)
          .with(raw_response: raw, context_type: context_type)
          .and_return(validated)
      end

      it "validated Hash を返す" do
        expect(subject).to eq(validated)
      end

      it "AiInvocationLog.record!(status: success)を呼ぶ" do
        subject
        expect(log_recorder).to have_received(:record!).with(
          hash_including(
            context_type: context_type,
            prompt: rendered_prompt,
            response: raw,
            status: "success"
          )
        )
      end
    end

    context "Invoker が nil 返却(タイムアウト or CLI 異常)+ fail_safe=skip の場合" do
      let(:fail_safe) { "skip" }

      before do
        allow(invoker).to receive(:invoke).and_return(nil)
      end

      it "nil を返す" do
        expect(subject).to be_nil
      end

      it "AiInvocationLog.record!(status: timeout)を呼ぶ" do
        subject
        expect(log_recorder).to have_received(:record!).with(
          hash_including(status: "timeout", response: nil)
        )
      end
    end

    context "Invoker が nil 返却(タイムアウト or CLI 異常)+ fail_safe=proceed の場合" do
      let(:fail_safe) { "proceed" }

      before do
        allow(invoker).to receive(:invoke).and_return(nil)
      end

      context "context_type=entry_filter の場合" do
        let(:context_type) { "entry_filter" }

        it "AI なし通過レスポンス {enter: true, reason: ...} を返す" do
          expect(subject).to eq({ "enter" => true, "reason" => "ai_filter_timeout_proceed_default" })
        end
      end

      context "context_type=position_sizing の場合" do
        let(:context_type) { "position_sizing" }

        it "AI なし通過レスポンス {size_multiplier: 1.0} を返す" do
          expect(subject).to eq({ "size_multiplier" => 1.0 })
        end
      end

      context "context_type=exception_close の場合" do
        let(:context_type) { "exception_close" }

        it "AI なし通過レスポンス {close: false, reason: ...} を返す" do
          expect(subject).to eq({ "close" => false, "reason" => "ai_filter_timeout_proceed_default" })
        end
      end
    end

    context "Invoker 成功 + Validator 失敗(JSON 失敗 / schema 違反)の場合" do
      let(:fail_safe) { "proceed" }
      let(:raw) { "not a json" }

      before do
        allow(invoker).to receive(:invoke).and_return(raw)
        allow(validator).to receive(:validate).and_return(nil)
      end

      it "fail_safe に関わらず nil を返す(エントリー見送り固定)" do
        expect(subject).to be_nil
      end

      it "AiInvocationLog.record!(status: validation_failed)を呼ぶ" do
        subject
        expect(log_recorder).to have_received(:record!).with(
          hash_including(status: "validation_failed", response: raw)
        )
      end
    end

    context "latency_ms 計測" do
      let(:fail_safe) { "skip" }
      let(:raw) { '{"enter": true, "reason": "ok"}' }
      let(:validated) { { "enter" => true } }

      before do
        allow(invoker).to receive(:invoke) do
          current_time[0] = current_time[0] + 0.5  # 500ms 経過
          raw
        end
        allow(validator).to receive(:validate).and_return(validated)
      end

      it "log に latency_ms=500 が記録される" do
        subject
        expect(log_recorder).to have_received(:record!).with(
          hash_including(latency_ms: 500)
        )
      end
    end
  end
end
