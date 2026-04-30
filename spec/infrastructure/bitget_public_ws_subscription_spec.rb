require "rails_helper"

RSpec.describe Infrastructure::BitgetPublicWsSubscription do
  let(:valid_attributes) do
    { channel: "ticker", inst_type: "USDT-FUTURES", inst_id: "BTCUSDT" }
  end

  describe "#initialize" do
    subject { described_class.new(**attributes) }

    context "全属性が valid な場合" do
      let(:attributes) { valid_attributes }

      it "構築成功し各 getter で値が取得できる" do
        result = subject
        expect(result.channel).to eq("ticker")
        expect(result.inst_type).to eq("USDT-FUTURES")
        expect(result.inst_id).to eq("BTCUSDT")
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

    context "USDT-FUTURES の ticker の場合" do
      it "Bitget WS API 仕様の Hash 表現を返す" do
        expect(subject).to eq(instType: "USDT-FUTURES", channel: "ticker", instId: "BTCUSDT")
      end
    end

    context "SPOT の candle1m の場合" do
      subject do
        described_class.new(
          channel: "candle1m",
          inst_type: "SPOT",
          inst_id: "ETHUSDT"
        ).to_args_hash
      end

      it "instType=SPOT, channel=candle1m, instId=ETHUSDT を返す" do
        expect(subject).to eq(instType: "SPOT", channel: "candle1m", instId: "ETHUSDT")
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
      let(:other) { described_class.new(**valid_attributes.merge(channel: "books5")) }

      it "== が false を返す" do
        expect(base).not_to eq(other)
      end
    end

    context "inst_type が異なる場合" do
      let(:other) { described_class.new(**valid_attributes.merge(inst_type: "SPOT")) }

      it "== が false を返す" do
        expect(base).not_to eq(other)
      end
    end

    context "inst_id が異なる場合" do
      let(:other) { described_class.new(**valid_attributes.merge(inst_id: "ETHUSDT")) }

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

    context "Hash のキーとして利用する場合" do
      it "同じ属性値の Subscription は Hash で同一キーとして扱われる" do
        hash = {}
        hash[described_class.new(**valid_attributes)] = :first
        hash[described_class.new(**valid_attributes)] = :second
        expect(hash.size).to eq(1)
        expect(hash.values.first).to eq(:second)
      end
    end
  end
end
