require "rails_helper"

RSpec.describe MarketData::FundingRateHistory, type: :model do
  describe "validations" do
    subject { described_class.new(attributes) }

    let(:valid_attributes) do
      {
        symbol: "BTCUSDT",
        funding_time: Time.current,
        funding_rate: "0.00010000"
      }
    end

    context "必須属性が全て揃っている場合" do
      let(:attributes) { valid_attributes }

      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end

    %i[symbol funding_time funding_rate].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { valid_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end
  end
end
