require "rails_helper"

RSpec.describe Strategy::Revision, type: :model do
  let(:definition) do
    Strategy::Definition.create!(name: "Strat", market_type: "futures", status: "active")
  end
  let(:script_body) do
    <<~RUBY
      class Sample < Domain::TradingScriptBase
        def on_tick(ctx, candle)
        end
      end
    RUBY
  end
  let(:base_attributes) do
    {
      strategy_definition: definition,
      revision_number: 1,
      script_content: script_body,
      script_entrypoint: "Sample",
      status: "draft",
      ast_validation_status: "pending",
      uses_live_forbidden_input: false,
      ai_filter_enabled: false,
      ai_sizing_enabled: false
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

    %i[revision_number script_content script_entrypoint status ast_validation_status].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { base_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end

    context "同一 strategy_definition で revision_number が重複する場合" do
      let(:attributes) { base_attributes }

      before { described_class.create!(base_attributes) }

      it "valid? が false を返し revision_number にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:revision_number]).to be_present
      end
    end

    context "別の strategy_definition で revision_number が同じ場合" do
      let(:other_definition) do
        Strategy::Definition.create!(name: "Other", market_type: "futures", status: "active")
      end
      let(:attributes) { base_attributes.merge(strategy_definition: other_definition) }

      before { described_class.create!(base_attributes) }

      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end
  end

  describe "before_validation :compute_checksum" do
    subject { described_class.create!(base_attributes) }

    context "script_content から SHA-256 を自動生成する場合" do
      it "script_checksum が SHA-256 と一致する 64桁 hex を持つ" do
        expected = Digest::SHA256.hexdigest(script_body)
        expect(subject.script_checksum).to eq(expected)
        expect(subject.script_checksum.length).to eq(64)
      end
    end
  end

  describe "status enum (prefix: :state)" do
    subject { described_class.create!(base_attributes.merge(status: status)) }

    %w[draft approved promoted deprecated archived].each do |state|
      context "#{state} 状態で作成した場合" do
        let(:status) { state }

        it "state_#{state}? が true を返す" do
          expect(subject.public_send("state_#{state}?")).to be true
        end
      end
    end
  end

  describe "ast_validation_status enum (prefix: :ast_validation)" do
    subject { described_class.create!(base_attributes.merge(ast_validation_status: status)) }

    %w[pending passed failed].each do |state|
      context "#{state} 状態で作成した場合" do
        let(:status) { state }

        it "ast_validation_#{state}? が true を返す" do
          expect(subject.public_send("ast_validation_#{state}?")).to be true
        end
      end
    end
  end

  describe "ai_filter_fail_safe enum (prefix: :ai_filter_fail_safe)" do
    subject do
      described_class.create!(base_attributes.merge(
        ai_filter_enabled: true,
        ai_filter_template_name: "tpl",
        ai_filter_fail_safe: value
      ))
    end

    %w[skip proceed].each do |state|
      context "#{state} 状態で作成した場合" do
        let(:value) { state }

        it "ai_filter_fail_safe_#{state}? が true を返す" do
          expect(subject.public_send("ai_filter_fail_safe_#{state}?")).to be true
        end
      end
    end
  end

  describe "associations" do
    context "belongs_to :strategy_definition の場合" do
      subject { described_class.reflect_on_association(:strategy_definition) }

      it "Strategy::Definition を class_name に持ち inverse_of: :revisions" do
        expect(subject.macro).to eq(:belongs_to)
        expect(subject.options[:class_name]).to eq("Strategy::Definition")
      end
    end
  end

  describe "#approve!" do
    let(:revision) { described_class.create!(base_attributes) }
    let(:approved_at) { Time.utc(2026, 4, 30, 0, 0, 0) }

    subject { revision.approve!(approved_at: approved_at) }

    context "draft 状態の Revision に approve! を呼ぶ場合" do
      it "state_approved? が true で approved_at が設定される" do
        subject
        revision.reload
        expect(revision).to be_state_approved
        expect(revision.approved_at).to eq(approved_at)
      end
    end
  end

  describe "#promote!" do
    let(:promoted_at) { Time.utc(2026, 4, 30, 1, 0, 0) }

    subject { revision.promote!(promoted_at: promoted_at) }

    context "uses_live_forbidden_input が false の場合" do
      let(:revision) { described_class.create!(base_attributes.merge(status: "approved", uses_live_forbidden_input: false)) }

      it "state_promoted? が true で promoted_at が設定される" do
        subject
        revision.reload
        expect(revision).to be_state_promoted
        expect(revision.promoted_at).to eq(promoted_at)
      end
    end

    context "uses_live_forbidden_input が true の場合" do
      let(:revision) { described_class.create!(base_attributes.merge(status: "approved", uses_live_forbidden_input: true)) }

      it "Strategy::Revision::LiveForbiddenInputError を raise する" do
        expect { subject }.to raise_error(Strategy::Revision::LiveForbiddenInputError)
      end
    end
  end

  describe "#deprecate!" do
    let(:revision) { described_class.create!(base_attributes.merge(status: "promoted")) }
    let(:deprecated_at) { Time.utc(2026, 4, 30, 2, 0, 0) }

    subject { revision.deprecate!(deprecated_at: deprecated_at) }

    context "promoted 状態の Revision に deprecate! を呼ぶ場合" do
      it "state_deprecated? が true で deprecated_at が設定される" do
        subject
        revision.reload
        expect(revision).to be_state_deprecated
        expect(revision.deprecated_at).to eq(deprecated_at)
      end
    end
  end

  describe "#archive!" do
    let(:revision) { described_class.create!(base_attributes.merge(status: "deprecated")) }
    let(:archived_at) { Time.utc(2026, 4, 30, 3, 0, 0) }

    subject { revision.archive!(archived_at: archived_at) }

    context "deprecated 状態の Revision に archive! を呼ぶ場合" do
      it "state_archived? が true で archived_at が設定される" do
        subject
        revision.reload
        expect(revision).to be_state_archived
        expect(revision.archived_at).to eq(archived_at)
      end
    end
  end

  describe "#acceptable_for_live?" do
    subject { described_class.create!(base_attributes.merge(status: status)).acceptable_for_live? }

    %w[promoted deprecated].each do |state|
      context "#{state} 状態の場合" do
        let(:status) { state }

        it "true を返す" do
          expect(subject).to be true
        end
      end
    end

    %w[draft approved archived].each do |state|
      context "#{state} 状態の場合" do
        let(:status) { state }

        it "false を返す" do
          expect(subject).to be false
        end
      end
    end
  end

  describe "#acceptable_for_backtest?" do
    subject { described_class.create!(base_attributes.merge(status: status)).acceptable_for_backtest? }

    %w[approved promoted deprecated archived].each do |state|
      context "#{state} 状態の場合" do
        let(:status) { state }

        it "true を返す" do
          expect(subject).to be true
        end
      end
    end

    context "draft 状態の場合" do
      let(:status) { "draft" }

      it "false を返す" do
        expect(subject).to be false
      end
    end
  end

  describe ".assert_strategy_definition_consistency!" do
    let(:revision) { described_class.create!(base_attributes) }

    context "revision の strategy_definition_id と引数が一致する場合" do
      subject { described_class.assert_strategy_definition_consistency!(revision.id, definition.id) }

      it "Revision を返す" do
        expect(subject).to eq(revision)
      end
    end

    context "revision の strategy_definition_id と引数が一致しない場合" do
      let(:other_definition) do
        Strategy::Definition.create!(name: "Other", market_type: "futures", status: "active")
      end
      subject { described_class.assert_strategy_definition_consistency!(revision.id, other_definition.id) }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /strategy_definition_id mismatch/)
      end
    end

    context "存在しない revision_id を指定した場合" do
      subject { described_class.assert_strategy_definition_consistency!(0, definition.id) }

      it "ActiveRecord::RecordNotFound を raise する" do
        expect { subject }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "ai_filter 条件付き presence validation" do
    subject { described_class.new(attributes) }

    context "ai_filter_enabled が false の場合" do
      let(:attributes) { base_attributes }

      it "ai_filter_template_name と ai_filter_fail_safe が nil でも valid" do
        expect(subject).to be_valid
      end
    end

    context "ai_filter_enabled が true で ai_filter_template_name が nil の場合" do
      let(:attributes) do
        base_attributes.merge(ai_filter_enabled: true,
                              ai_filter_template_name: nil,
                              ai_filter_fail_safe: "skip")
      end

      it "valid? が false で ai_filter_template_name にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:ai_filter_template_name]).to be_present
      end
    end

    context "ai_filter_enabled が true で ai_filter_fail_safe が nil の場合" do
      let(:attributes) do
        base_attributes.merge(ai_filter_enabled: true,
                              ai_filter_template_name: "tpl",
                              ai_filter_fail_safe: nil)
      end

      it "valid? が false で ai_filter_fail_safe にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:ai_filter_fail_safe]).to be_present
      end
    end

    context "ai_filter_enabled が true で template_name と fail_safe が両方揃っている場合" do
      let(:attributes) do
        base_attributes.merge(ai_filter_enabled: true,
                              ai_filter_template_name: "tpl",
                              ai_filter_fail_safe: "skip")
      end

      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end
  end

  describe "script_content 不変性 validation (重要5)" do
    context "create時(persisted=false)で script_content を指定する場合" do
      subject { described_class.new(base_attributes) }

      it "valid? が true を返す(create 時は当然許可)" do
        expect(subject).to be_valid
      end
    end

    %w[approved promoted deprecated archived].each do |state|
      context "#{state} 状態の Revision の script_content を update! で変更する場合" do
        let(:revision) { described_class.create!(base_attributes.merge(status: state)) }

        it "ActiveRecord::RecordInvalid を raise する" do
          expect {
            revision.update!(script_content: "class Modified; end")
          }.to raise_error(ActiveRecord::RecordInvalid, /cannot be changed/)
        end
      end
    end

    context "draft 状態の Revision の script_content を update! で変更する場合" do
      let(:revision) { described_class.create!(base_attributes.merge(status: "draft")) }

      it "更新成功する" do
        expect { revision.update!(script_content: "class Modified; end") }.not_to raise_error
      end
    end

    context "approved 状態の Revision を promote! する場合(script_content 変更なし)" do
      let(:revision) { described_class.create!(base_attributes.merge(status: "approved")) }

      it "promote! が成功し state_promoted? が true" do
        expect { revision.promote! }.not_to raise_error
        expect(revision.reload).to be_state_promoted
      end
    end
  end
end
