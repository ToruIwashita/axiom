require "rails_helper"

RSpec.describe User, type: :model do
  describe "validations" do
    subject { described_class.new(attributes) }

    let(:valid_attributes) do
      { email: "test@example.com", name: "Test User" }
    end

    context "必須属性が全て揃っている場合" do
      let(:attributes) { valid_attributes }

      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end

    %i[email name].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { valid_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end

    context "email が既存ユーザーと重複する場合" do
      let(:attributes) { valid_attributes }

      before { described_class.create!(valid_attributes) }

      it "valid? が false を返し email にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:email]).to be_present
      end
    end
  end
end
