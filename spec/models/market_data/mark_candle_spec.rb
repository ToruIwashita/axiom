require "rails_helper"

RSpec.describe MarketData::MarkCandle, type: :model do
  describe "validations" do
    subject { described_class.new(attributes) }

    let(:valid_attributes) do
      {
        symbol: "BTCUSDT",
        granularity: "1H",
        ts: Time.current,
        open: 50_000,
        high: 50_500,
        low: 49_500,
        close: 50_200
      }
    end

    context "必須属性が全て揃っている場合" do
      let(:attributes) { valid_attributes }

      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end

    %i[symbol granularity ts open high low close].each do |attr|
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
