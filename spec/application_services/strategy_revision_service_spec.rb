require "rails_helper"

RSpec.describe ApplicationServices::StrategyRevisionService do
  let(:passed_result) do
    Domain::StrategyScriptAstValidatorService::Result.new(
      status: :passed, report: nil, uses_live_forbidden_input: false
    )
  end
  let(:failed_result) do
    Domain::StrategyScriptAstValidatorService::Result.new(
      status: :failed, report: "violation: forbidden API", uses_live_forbidden_input: false
    )
  end
  let(:ast_validator) { instance_double(Domain::StrategyScriptAstValidatorService) }
  let(:service) { described_class.new(ast_validator: ast_validator) }
  let!(:definition) { Strategy::Definition.create!(name: "Rev Strat", market_type: "futures", status: "active") }
  let(:script_body) do
    <<~RUBY
      class Sample < Domain::TradingScriptBase
        def on_tick(ctx, candle); end
      end
    RUBY
  end

  describe "#create_draft" do
    subject do
      service.create_draft(
        definition_id: definition.id,
        script_content: script_body,
        script_entrypoint: "Sample"
      )
    end

    context "AST validator が passed を返す場合" do
      before { allow(ast_validator).to receive(:validate).with(script_body).and_return(passed_result) }

      it "draft 状態 + ast_validation_passed の Revision を作成する" do
        expect { subject }.to change { Strategy::Revision.count }.by(1)
        expect(subject).to be_state_draft
        expect(subject).to be_ast_validation_passed
        expect(subject.uses_live_forbidden_input).to be false
        expect(subject.strategy_definition).to eq(definition)
        expect(subject.revision_number).to eq(1)
      end
    end

    context "AST validator が failed を返す場合" do
      before { allow(ast_validator).to receive(:validate).with(script_body).and_return(failed_result) }

      it "Revision は作成されるが ast_validation_failed + report が記録される" do
        expect(subject).to be_state_draft
        expect(subject).to be_ast_validation_failed
        expect(subject.ast_validation_report).to eq("violation: forbidden API")
      end
    end

    context "同一 Definition で 2 件目を作成する場合" do
      before do
        allow(ast_validator).to receive(:validate).and_return(passed_result)
        Strategy::Revision.create!(
          strategy_definition: definition,
          revision_number: 1,
          script_content: script_body,
          script_entrypoint: "Sample",
          status: "draft",
          ast_validation_status: "passed",
          uses_live_forbidden_input: false,
          ai_filter_enabled: false,
          ai_sizing_enabled: false
        )
      end

      it "revision_number が 2 でインクリメントされる" do
        expect(subject.revision_number).to eq(2)
      end
    end

    context "AI フィルタを有効化して作成する場合" do
      subject do
        service.create_draft(
          definition_id: definition.id,
          script_content: script_body,
          script_entrypoint: "Sample",
          ai_filter_enabled: true,
          ai_filter_template_name: "tpl_v1",
          ai_filter_fail_safe: "skip",
          ai_filter_timeout_sec: 15
        )
      end

      before { allow(ast_validator).to receive(:validate).and_return(passed_result) }

      it "ai_filter_* 属性が反映される" do
        expect(subject.ai_filter_enabled).to be true
        expect(subject.ai_filter_template_name).to eq("tpl_v1")
        expect(subject.ai_filter_fail_safe).to eq("skip")
        expect(subject.ai_filter_timeout_sec).to eq(15)
      end
    end
  end

  describe "#approve" do
    let(:revision) do
      Strategy::Revision.create!(
        strategy_definition: definition,
        revision_number: 1,
        script_content: script_body,
        script_entrypoint: "Sample",
        status: "draft",
        ast_validation_status: "passed",
        uses_live_forbidden_input: false,
        ai_filter_enabled: false,
        ai_sizing_enabled: false
      )
    end

    subject { service.approve(revision_id: revision.id) }

    context "draft Revision で AST 再検証 passed の場合" do
      before { allow(ast_validator).to receive(:validate).with(revision.script_content).and_return(passed_result) }

      it "approved 状態に遷移する" do
        result = subject
        expect(result).to be_state_approved
        expect(result.approved_at).to be_present
      end
    end

    context "draft Revision で AST 再検証 failed の場合" do
      before { allow(ast_validator).to receive(:validate).and_return(failed_result) }

      it "ApprovalError を raise し Revision は draft のまま" do
        expect { subject }.to raise_error(ApplicationServices::StrategyRevisionService::ApprovalError, /AST validation failed/)
        expect(revision.reload).to be_state_draft
      end
    end

    context "draft 以外の Revision に approve を呼ぶ場合" do
      let(:revision) do
        Strategy::Revision.create!(
          strategy_definition: definition,
          revision_number: 1,
          script_content: script_body,
          script_entrypoint: "Sample",
          status: "approved",
          ast_validation_status: "passed",
          uses_live_forbidden_input: false,
          ai_filter_enabled: false,
          ai_sizing_enabled: false,
          approved_at: Time.current
        )
      end

      it "ApprovalError を raise する(revision must be draft)" do
        expect { subject }.to raise_error(ApplicationServices::StrategyRevisionService::ApprovalError, /must be draft/)
      end
    end
  end

  describe "#promote" do
    subject { service.promote(revision_id: revision.id) }

    context "approved 状態かつ uses_live_forbidden_input == false の Revision の場合" do
      let(:revision) do
        Strategy::Revision.create!(
          strategy_definition: definition,
          revision_number: 1,
          script_content: script_body,
          script_entrypoint: "Sample",
          status: "approved",
          ast_validation_status: "passed",
          uses_live_forbidden_input: false,
          ai_filter_enabled: false,
          ai_sizing_enabled: false,
          approved_at: Time.current
        )
      end

      it "promoted 状態に遷移し promoted_at が設定される" do
        result = subject
        expect(result).to be_state_promoted
        expect(result.promoted_at).to be_present
      end
    end

    context "uses_live_forbidden_input == true の Revision の場合" do
      let(:revision) do
        Strategy::Revision.create!(
          strategy_definition: definition,
          revision_number: 1,
          script_content: script_body,
          script_entrypoint: "Sample",
          status: "approved",
          ast_validation_status: "passed",
          uses_live_forbidden_input: true,
          ai_filter_enabled: false,
          ai_sizing_enabled: false,
          approved_at: Time.current
        )
      end

      it "Strategy::Revision::LiveForbiddenInputError を raise し Revision は approved のまま" do
        expect { subject }.to raise_error(Strategy::Revision::LiveForbiddenInputError)
        expect(revision.reload).to be_state_approved
      end
    end

    context "存在しない revision_id を渡した場合" do
      subject { service.promote(revision_id: 0) }

      it "ActiveRecord::RecordNotFound を raise する" do
        expect { subject }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "#get" do
    let!(:revision) do
      Strategy::Revision.create!(
        strategy_definition: definition,
        revision_number: 1,
        script_content: script_body,
        script_entrypoint: "Sample",
        status: "draft",
        ast_validation_status: "passed",
        uses_live_forbidden_input: false,
        ai_filter_enabled: false,
        ai_sizing_enabled: false
      )
    end

    context "存在する revision_id を渡した場合" do
      subject { service.get(revision_id: revision.id) }

      it "Strategy::Revision を返す" do
        expect(subject).to eq(revision)
      end
    end

    context "存在しない revision_id を渡した場合" do
      subject { service.get(revision_id: 0) }

      it "ActiveRecord::RecordNotFound を raise する" do
        expect { subject }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "#list_by_definition" do
    subject { service.list_by_definition(definition_id: definition.id).to_a }

    context "複数 revision が存在する場合" do
      let!(:r1) do
        Strategy::Revision.create!(strategy_definition: definition, revision_number: 1, script_content: script_body,
                                    script_entrypoint: "Sample", status: "draft", ast_validation_status: "passed",
                                    uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false)
      end
      let!(:r2) do
        Strategy::Revision.create!(strategy_definition: definition, revision_number: 2, script_content: script_body,
                                    script_entrypoint: "Sample", status: "draft", ast_validation_status: "passed",
                                    uses_live_forbidden_input: false, ai_filter_enabled: false, ai_sizing_enabled: false)
      end

      it "revision_number desc 順で返される" do
        expect(subject).to eq([ r2, r1 ])
      end
    end
  end
end
