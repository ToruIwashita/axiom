require "rails_helper"

RSpec.describe Strategy::Definition, type: :model do
  describe "validations" do
    subject { described_class.new(attributes) }

    let(:valid_attributes) do
      {
        name: "Sample Strategy",
        description: "test description",
        market_type: "futures",
        status: "active"
      }
    end

    context "必須属性が全て揃っている場合" do
      let(:attributes) { valid_attributes }

      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end

    %i[name market_type status].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { valid_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end
  end

  describe "status enum" do
    let(:definition) do
      described_class.create!(name: "S", market_type: "futures", status: "active")
    end

    context "active で作成した場合" do
      subject { definition }

      it "state_active? が true を返す" do
        expect(subject).to be_state_active
      end
    end

    context "archived に遷移した場合" do
      subject { definition.tap { |d| d.update!(status: "archived") } }

      it "state_archived? が true を返す" do
        expect(subject).to be_state_archived
      end
    end
  end

  describe "associations" do
    context "has_many :revisions の場合" do
      subject { described_class.reflect_on_association(:revisions) }

      it "Strategy::Revision を class_name に持ち strategy_definition_id を foreign_key に持つ" do
        expect(subject.macro).to eq(:has_many)
        expect(subject.options[:class_name]).to eq("Strategy::Revision")
        expect(subject.options[:foreign_key]).to eq(:strategy_definition_id)
        expect(subject.options[:inverse_of]).to eq(:strategy_definition)
      end
    end

    context "has_many :live_trading_sessions の場合(Phase 3.1 追加 / レビュー R-2 反映)" do
      subject { described_class.reflect_on_association(:live_trading_sessions) }

      it "LiveTrading::Session を class_name + strategy_definition_id を foreign_key + restrict_with_error" do
        expect(subject.macro).to eq(:has_many)
        expect(subject.options[:class_name]).to eq("LiveTrading::Session")
        expect(subject.options[:foreign_key]).to eq(:strategy_definition_id)
        expect(subject.options[:dependent]).to eq(:restrict_with_error)
      end
    end
  end
end
