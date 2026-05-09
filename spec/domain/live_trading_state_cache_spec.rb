require "rails_helper"

RSpec.describe Domain::LiveTradingStateCache do
  let(:logger) { instance_double(Logger, warn: nil) }
  let(:cache) { described_class.new(logger: logger) }

  describe "初期値" do
    it "balance は BigDecimal(0)" do
      expect(cache.balance).to eq(BigDecimal("0"))
    end

    it "position は no-position(side=nil / size=0 / entry_price=0)" do
      pos = cache.position
      expect(pos.side).to be_nil
      expect(pos.size).to eq(BigDecimal("0"))
      expect(pos.entry_price).to eq(BigDecimal("0"))
    end

    it "snapshot で [balance, position] のペアを取得できる" do
      balance, position = cache.snapshot
      expect(balance).to eq(BigDecimal("0"))
      expect(position).to be_a(Domain::PositionValueObject)
    end
  end

  describe "#update_balance" do
    context "正常な値" do
      it "BigDecimal で更新する" do
        cache.update_balance("1234.56")
        expect(cache.balance).to eq(BigDecimal("1234.56"))
      end

      it "Numeric も対応" do
        cache.update_balance(1000)
        expect(cache.balance).to eq(BigDecimal("1000"))
      end
    end

    context "不正値ガード" do
      it "nil で cache 不変 + nil 返却" do
        cache.update_balance("100")
        expect(cache.update_balance(nil)).to be_nil
        expect(cache.balance).to eq(BigDecimal("100"))
      end

      it "空文字で cache 不変" do
        cache.update_balance("100")
        expect(cache.update_balance("")).to be_nil
        expect(cache.balance).to eq(BigDecimal("100"))
      end

      it "不正な文字列で cache 不変" do
        cache.update_balance("100")
        expect(cache.update_balance("abc")).to be_nil
        expect(cache.balance).to eq(BigDecimal("100"))
      end
    end
  end

  describe "#apply_account_push" do
    context "正常 data" do
      let(:data) do
        [
          { "marginCoin" => "USDT", "available" => "5000.0", "frozen" => "0.0" },
          { "marginCoin" => "BTC", "available" => "0.5" }
        ]
      end

      it "margin_coin 該当 row の available 値で balance 更新" do
        cache.apply_account_push(data, margin_coin: "USDT")
        expect(cache.balance).to eq(BigDecimal("5000.0"))
      end
    end

    context "境界 / 不正 data" do
      it "data nil → cache 不変" do
        cache.update_balance("100")
        cache.apply_account_push(nil, margin_coin: "USDT")
        expect(cache.balance).to eq(BigDecimal("100"))
      end

      it "data 空配列 → cache 不変" do
        cache.update_balance("100")
        cache.apply_account_push([], margin_coin: "USDT")
        expect(cache.balance).to eq(BigDecimal("100"))
      end

      it "margin_coin 該当 row なし → cache 不変" do
        cache.update_balance("100")
        cache.apply_account_push([ { "marginCoin" => "BTC", "available" => "0.5" } ], margin_coin: "USDT")
        expect(cache.balance).to eq(BigDecimal("100"))
      end

      it "available nil → cache 不変" do
        cache.update_balance("100")
        cache.apply_account_push([ { "marginCoin" => "USDT", "available" => nil } ], margin_coin: "USDT")
        expect(cache.balance).to eq(BigDecimal("100"))
      end

      it "available 不正値 → cache 不変" do
        cache.update_balance("100")
        cache.apply_account_push([ { "marginCoin" => "USDT", "available" => "abc" } ], margin_coin: "USDT")
        expect(cache.balance).to eq(BigDecimal("100"))
      end
    end
  end

  describe "#apply_position_push" do
    context "正常 data" do
      let(:data) do
        [
          { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05", "openPriceAvg" => "50000" },
          { "symbol" => "ETHUSDT", "holdSide" => "short", "total" => "1.0", "openPriceAvg" => "3000" }
        ]
      end

      it "symbol 該当 row で position を更新(side/size/entry_price)" do
        cache.apply_position_push(data, symbol: "BTCUSDT")
        pos = cache.position
        expect(pos.side).to eq(:long)
        expect(pos.size).to eq(BigDecimal("0.05"))
        expect(pos.entry_price).to eq(BigDecimal("50000"))
      end
    end

    context "holdSide allow-list ガード" do
      it "long / short 以外(net 等)で cache 不変 + logger.warn" do
        original = cache.position
        data = [ { "symbol" => "BTCUSDT", "holdSide" => "net", "total" => "0.05", "openPriceAvg" => "50000" } ]
        cache.apply_position_push(data, symbol: "BTCUSDT")
        expect(cache.position).to equal(original)
        expect(logger).to have_received(:warn).with(/unknown holdSide=.*net/)
      end

      it "holdSide nil で cache 不変" do
        original = cache.position
        data = [ { "symbol" => "BTCUSDT", "holdSide" => nil, "total" => "0.05", "openPriceAvg" => "50000" } ]
        cache.apply_position_push(data, symbol: "BTCUSDT")
        expect(cache.position).to equal(original)
      end
    end

    context "BigDecimal nil/不正値ガード" do
      it "total nil で cache 不変" do
        original = cache.position
        data = [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => nil, "openPriceAvg" => "50000" } ]
        cache.apply_position_push(data, symbol: "BTCUSDT")
        expect(cache.position).to equal(original)
      end

      it "openPriceAvg 空文字で cache 不変" do
        original = cache.position
        data = [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05", "openPriceAvg" => "" } ]
        cache.apply_position_push(data, symbol: "BTCUSDT")
        expect(cache.position).to equal(original)
      end
    end

    context "境界 / 不正 data" do
      it "data nil で cache 不変" do
        original = cache.position
        cache.apply_position_push(nil, symbol: "BTCUSDT")
        expect(cache.position).to equal(original)
      end

      it "data 空配列で cache 不変" do
        original = cache.position
        cache.apply_position_push([], symbol: "BTCUSDT")
        expect(cache.position).to equal(original)
      end

      it "symbol 該当 row なしで cache 不変" do
        original = cache.position
        data = [ { "symbol" => "ETHUSDT", "holdSide" => "short", "total" => "1.0", "openPriceAvg" => "3000" } ]
        cache.apply_position_push(data, symbol: "BTCUSDT")
        expect(cache.position).to equal(original)
      end
    end
  end

  describe "thread-safety" do
    it "snapshot は balance / position を 1 ロック内に取得する(整合性保証)" do
      cache.update_balance("1000")
      cache.apply_position_push(
        [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.1", "openPriceAvg" => "50000" } ],
        symbol: "BTCUSDT"
      )
      balance, position = cache.snapshot
      expect(balance).to eq(BigDecimal("1000"))
      expect(position.side).to eq(:long)
    end
  end
end
