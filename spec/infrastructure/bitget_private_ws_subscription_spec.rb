require "rails_helper"

RSpec.describe Infrastructure::BitgetPrivateWsSubscription do
  let(:valid_attributes) do
    { channel: "orders", inst_type: "USDT-FUTURES", inst_id: "default" }
  end

  describe "#initialize" do
    subject { described_class.new(**attributes) }

    context "全属性が valid な場合" do
      let(:attributes) { valid_attributes }

      it "構築成功し各 getter で値が取得できる" do
        result = subject
        expect(result.channel).to eq("orders")
        expect(result.inst_type).to eq("USDT-FUTURES")
        expect(result.inst_id).to eq("default")
      end
    end

    context "Private 6 チャネル全てが受理される" do
      %w[orders orders-algo fill positions positions-history account].each do |private_channel|
        it "channel=#{private_channel} で構築成功" do
          result = described_class.new(channel: private_channel, inst_type: "USDT-FUTURES", inst_id: "default")
          expect(result.channel).to eq(private_channel)
        end
      end
    end

    context "inst_type が小文字の場合" do
      let(:attributes) { valid_attributes.merge(inst_type: "usdt-futures") }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /inst_type/)
      end
    end

    context "inst_type が許可外の値の場合" do
      let(:attributes) { valid_attributes.merge(inst_type: "FOREX") }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /inst_type/)
      end
    end

    context "channel が空文字の場合" do
      let(:attributes) { valid_attributes.merge(channel: "") }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /channel/)
      end
    end

    context "channel が nil の場合" do
      let(:attributes) { valid_attributes.merge(channel: nil) }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /channel/)
      end
    end

    context "inst_id が空文字の場合" do
      let(:attributes) { valid_attributes.merge(inst_id: "") }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /inst_id/)
      end
    end

    context "inst_id が nil の場合" do
      let(:attributes) { valid_attributes.merge(inst_id: nil) }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /inst_id/)
      end
    end
  end

  describe "#to_args_hash" do
    subject { described_class.new(**valid_attributes).to_args_hash }

    context "USDT-FUTURES の orders チャネルの場合" do
      it "Bitget WS API 仕様の Hash 表現を返す" do
        expect(subject).to eq(instType: "USDT-FUTURES", channel: "orders", instId: "default")
      end
    end

    context "特定 symbol を指定した場合(default 以外)" do
      subject do
        described_class.new(
          channel: "fill",
          inst_type: "USDT-FUTURES",
          inst_id: "BTCUSDT"
        ).to_args_hash
      end

      it "instType / channel / instId を返す" do
        expect(subject).to eq(instType: "USDT-FUTURES", channel: "fill", instId: "BTCUSDT")
      end
    end
  end

  describe "等価判定 (#== / #eql? / #hash)" do
    let(:base) { described_class.new(**valid_attributes) }

    context "同じ属性値の場合" do
      let(:other) { described_class.new(**valid_attributes) }

      it "== / eql? が true で hash が一致する" do
        expect(base).to eq(other)
        expect(base.eql?(other)).to be true
        expect(base.hash).to eq(other.hash)
      end
    end

    context "channel が異なる場合" do
      let(:other) { described_class.new(**valid_attributes.merge(channel: "fill")) }

      it "== が false を返す" do
        expect(base).not_to eq(other)
      end
    end

    context "inst_type が異なる場合" do
      let(:other) { described_class.new(**valid_attributes.merge(inst_type: "COIN-FUTURES")) }

      it "== が false を返す" do
        expect(base).not_to eq(other)
      end
    end

    context "inst_id が異なる場合" do
      let(:other) { described_class.new(**valid_attributes.merge(inst_id: "BTCUSDT")) }

      it "== が false を返す" do
        expect(base).not_to eq(other)
      end
    end

    context "Set 内で重複排除される場合" do
      it "同じ属性値の Subscription は Set 内で 1 件として扱われる" do
        set = Set.new
        set << described_class.new(**valid_attributes)
        set << described_class.new(**valid_attributes)
        expect(set.size).to eq(1)
      end
    end

    context "BitgetPublicWsSubscription との比較" do
      let(:public_sub) do
        Infrastructure::BitgetPublicWsSubscription.new(**valid_attributes)
      end

      it "別クラスのため == が false を返す(型分離)" do
        expect(base).not_to eq(public_sub)
      end
    end
  end
end
