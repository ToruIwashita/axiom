require "rails_helper"

RSpec.describe Risk::Policy, type: :model do
  let(:valid_attributes) do
    {
      name: "default",
      max_drawdown_pct: 10.0,
      consecutive_loss_limit: 3,
      max_position_exposure_usdt: 1_000.0,
      max_leverage: 10,
      cooldown_minutes: 60,
      daily_loss_limit_usdt: 100.0
    }
  end

  describe "validations" do
    subject { described_class.new(attributes) }

    context "全属性が valid な場合" do
      let(:attributes) { valid_attributes }

      it "valid? が true を返す" do
        expect(subject).to be_valid
      end
    end

    %i[
      name
      max_drawdown_pct
      consecutive_loss_limit
      max_position_exposure_usdt
      max_leverage
      cooldown_minutes
      daily_loss_limit_usdt
    ].each do |attr|
      context "#{attr} が nil の場合" do
        let(:attributes) { valid_attributes.merge(attr => nil) }

        it "valid? が false を返し #{attr} にエラーが付与される" do
          expect(subject).not_to be_valid
          expect(subject.errors[attr]).to be_present
        end
      end
    end

    context "name が重複する場合" do
      before do
        described_class.create!(valid_attributes)
      end

      let(:attributes) { valid_attributes }

      it "valid? が false を返し name にエラーが付与される" do
        expect(subject).not_to be_valid
        expect(subject.errors[:name]).to be_present
      end
    end

    context "max_drawdown_pct が境界値の場合" do
      it "0 で error,0.01 で valid,100 で valid,100.01 で error,負値で error となる" do
        expect(described_class.new(valid_attributes.merge(max_drawdown_pct: 0))).not_to be_valid
        expect(described_class.new(valid_attributes.merge(max_drawdown_pct: 0.01))).to be_valid
        expect(described_class.new(valid_attributes.merge(max_drawdown_pct: 100))).to be_valid
        expect(described_class.new(valid_attributes.merge(max_drawdown_pct: 100.01))).not_to be_valid
        expect(described_class.new(valid_attributes.merge(max_drawdown_pct: -1))).not_to be_valid
      end
    end

    context "consecutive_loss_limit が境界値の場合" do
      it "0 で error,1 で valid,小数で error となる" do
        expect(described_class.new(valid_attributes.merge(consecutive_loss_limit: 0))).not_to be_valid
        expect(described_class.new(valid_attributes.merge(consecutive_loss_limit: 1))).to be_valid
        expect(described_class.new(valid_attributes.merge(consecutive_loss_limit: 1.5))).not_to be_valid
      end
    end

    context "max_position_exposure_usdt が境界値の場合" do
      it "0 で error,0.01 で valid,負値で error となる" do
        expect(described_class.new(valid_attributes.merge(max_position_exposure_usdt: 0))).not_to be_valid
        expect(described_class.new(valid_attributes.merge(max_position_exposure_usdt: 0.01))).to be_valid
        expect(described_class.new(valid_attributes.merge(max_position_exposure_usdt: -1))).not_to be_valid
      end
    end

    context "max_leverage が境界値の場合" do
      it "0 で error,1 で valid,125 で valid,126 で error,小数で error となる" do
        expect(described_class.new(valid_attributes.merge(max_leverage: 0))).not_to be_valid
        expect(described_class.new(valid_attributes.merge(max_leverage: 1))).to be_valid
        expect(described_class.new(valid_attributes.merge(max_leverage: 125))).to be_valid
        expect(described_class.new(valid_attributes.merge(max_leverage: 126))).not_to be_valid
        expect(described_class.new(valid_attributes.merge(max_leverage: 1.5))).not_to be_valid
      end
    end

    context "cooldown_minutes が境界値の場合" do
      it "-1 で error,0 で valid,小数で error となる" do
        expect(described_class.new(valid_attributes.merge(cooldown_minutes: -1))).not_to be_valid
        expect(described_class.new(valid_attributes.merge(cooldown_minutes: 0))).to be_valid
        expect(described_class.new(valid_attributes.merge(cooldown_minutes: 1.5))).not_to be_valid
      end
    end

    context "daily_loss_limit_usdt が境界値の場合" do
      it "0 で error,0.01 で valid,負値で error となる" do
        expect(described_class.new(valid_attributes.merge(daily_loss_limit_usdt: 0))).not_to be_valid
        expect(described_class.new(valid_attributes.merge(daily_loss_limit_usdt: 0.01))).to be_valid
        expect(described_class.new(valid_attributes.merge(daily_loss_limit_usdt: -1))).not_to be_valid
      end
    end
  end

  describe ".table_name" do
    subject { described_class.table_name }

    it "risk_policies を返す" do
      expect(subject).to eq("risk_policies")
    end
  end

  # 設計時ピアレビュー軽微c 対応:
  # Risk::Policy 自体は update を許可する(コード制約は強制しない)。
  # 運用ルールでは soft-update 禁止/新レコード作成を推奨するが,
  # その統制は Phase 2/3 開発ガイドで明文化する。
  describe "属性更新の挙動" do
    subject { policy.update!(max_drawdown_pct: 20.0) }

    let(:policy) { described_class.create!(valid_attributes) }

    context "Risk::Policy 属性を update した場合" do
      it "更新が許可される(コード制約は強制しない,運用ルールで統制)" do
        expect { subject }.to change { policy.reload.max_drawdown_pct }.from(10.0).to(20.0)
      end
    end
  end

  # Phase 3.1 追加 / レビュー R-2 反映
  describe "associations" do
    context "has_many :live_trading_sessions の場合" do
      subject { described_class.reflect_on_association(:live_trading_sessions) }

      it "LiveTrading::Session を class_name + risk_policy_id を foreign_key + restrict_with_error" do
        expect(subject.macro).to eq(:has_many)
        expect(subject.options[:class_name]).to eq("LiveTrading::Session")
        expect(subject.options[:foreign_key]).to eq(:risk_policy_id)
        expect(subject.options[:dependent]).to eq(:restrict_with_error)
      end
    end
  end
end
