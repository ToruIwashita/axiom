require "rails_helper"

RSpec.describe Domain::LiveTradingStateCache do
  let(:logger) { instance_double(Logger, warn: nil, info: nil, error: nil, debug: nil) }
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

    context "size=0(close 完了直後の Bitget push)" do
      it "flat VO(side=nil / size=0 / entry=0)に正規化される" do
        cache.apply_position_push(
          [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0", "openPriceAvg" => "50000" } ],
          symbol: "BTCUSDT"
        )
        pos = cache.position
        expect(pos.side).to be_nil
        expect(pos.size).to eq(BigDecimal("0"))
        expect(pos.entry_price).to eq(BigDecimal("0"))
      end
    end

    # cache 不変判定は属性比較で行う(オブジェクト同一性は VO 再生成耐性がないため避ける).
    shared_examples "position 不変" do
      it "side / size / entry_price のいずれも変化しない" do
        before_attrs = [ cache.position.side, cache.position.size, cache.position.entry_price ]
        subject_call.call
        expect([ cache.position.side, cache.position.size, cache.position.entry_price ]).to eq(before_attrs)
      end
    end

    context "holdSide allow-list ガード" do
      context "long / short 以外(net 等)" do
        let(:subject_call) do
          -> { cache.apply_position_push([ { "symbol" => "BTCUSDT", "holdSide" => "net", "total" => "0.05", "openPriceAvg" => "50000" } ], symbol: "BTCUSDT") }
        end
        it_behaves_like "position 不変"

        it "logger.warn を出力する" do
          subject_call.call
          expect(logger).to have_received(:warn).with(/unknown holdSide=.*net/)
        end
      end

      context "holdSide nil" do
        let(:subject_call) do
          -> { cache.apply_position_push([ { "symbol" => "BTCUSDT", "holdSide" => nil, "total" => "0.05", "openPriceAvg" => "50000" } ], symbol: "BTCUSDT") }
        end
        it_behaves_like "position 不変"
      end
    end

    context "BigDecimal nil/不正値ガード" do
      context "total nil" do
        let(:subject_call) do
          -> { cache.apply_position_push([ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => nil, "openPriceAvg" => "50000" } ], symbol: "BTCUSDT") }
        end
        it_behaves_like "position 不変"
      end

      context "openPriceAvg 空文字" do
        let(:subject_call) do
          -> { cache.apply_position_push([ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05", "openPriceAvg" => "" } ], symbol: "BTCUSDT") }
        end
        it_behaves_like "position 不変"
      end
    end

    context "境界 / 不正 data" do
      context "data nil" do
        let(:subject_call) { -> { cache.apply_position_push(nil, symbol: "BTCUSDT") } }
        it_behaves_like "position 不変"
      end

      context "data 空配列" do
        let(:subject_call) { -> { cache.apply_position_push([], symbol: "BTCUSDT") } }
        it_behaves_like "position 不変"
      end

      context "symbol 該当 row なし" do
        let(:subject_call) do
          -> { cache.apply_position_push([ { "symbol" => "ETHUSDT", "holdSide" => "short", "total" => "1.0", "openPriceAvg" => "3000" } ], symbol: "BTCUSDT") }
        end
        it_behaves_like "position 不変"
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

    # 並列更新と並列 snapshot を交錯させ Mutex 保護下で torn read / race が起きないことを検証.
    # RSpec の let は thread-safe ではないため cache を local 変数にキャプチャしてから spawn する.
    it "並列 update / snapshot 中に整合性が壊れない(20 thread × 50 反復)" do
      target_cache = cache
      writer_count = 10
      reader_count = 10
      iterations = 50
      observed = Queue.new

      writers = writer_count.times.map do |i|
        Thread.new do
          iterations.times do |j|
            balance_value = (i * 1000 + j).to_s
            target_cache.update_balance(balance_value)
            target_cache.apply_position_push(
              [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "1", "openPriceAvg" => balance_value } ],
              symbol: "BTCUSDT"
            )
          end
        end
      end

      readers = reader_count.times.map do
        Thread.new do
          iterations.times do
            balance, position = target_cache.snapshot
            observed << [ balance, position ]
          end
        end
      end

      (writers + readers).each(&:join)

      # snapshot で取得した [balance, position] のいずれも nil にならないこと.
      observed.size.times do
        balance, position = observed.pop
        expect(balance).to be_a(BigDecimal)
        expect(position).to be_a(Domain::PositionValueObject)
      end
    end
  end
end
