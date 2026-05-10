require "rails_helper"

RSpec.describe Domain::KillSwitchExecutorService do
  let(:order_endpoint) { instance_double(Infrastructure::BitgetOrderEndpoint) }
  let(:position_endpoint) { instance_double(Infrastructure::BitgetPositionEndpoint) }
  let(:logger) { instance_double(Logger, warn: nil, info: nil, error: nil, debug: nil) }
  let(:service) do
    described_class.new(
      order_endpoint: order_endpoint,
      position_endpoint: position_endpoint,
      logger: logger
    )
  end
  let(:session) { instance_double(LiveTrading::Session, symbol: "BTCUSDT") }

  describe "#execute(mode: :cancel_only)" do
    before do
      allow(order_endpoint).to receive(:orders_pending).and_return("data" => [])
      allow(order_endpoint).to receive(:orders_plan_pending).and_return("data" => [])
      allow(order_endpoint).to receive(:cancel_order)
      allow(order_endpoint).to receive(:cancel_plan_order)
    end

    context "未約定の通常注文と plan order が存在する場合" do
      let(:pending_orders) do
        [
          { "orderId" => "ord-1", "symbol" => "BTCUSDT" },
          { "orderId" => "ord-2", "symbol" => "BTCUSDT" }
        ]
      end
      let(:pending_plans) do
        [ { "orderId" => "plan-1", "symbol" => "BTCUSDT" } ]
      end

      before do
        allow(order_endpoint).to receive(:orders_pending).and_return("data" => pending_orders)
        allow(order_endpoint).to receive(:orders_plan_pending).and_return("data" => pending_plans)
      end

      it "全 pending orders を cancel_order で取り消す" do
        expect(order_endpoint).to receive(:cancel_order).with(symbol: "BTCUSDT", order_id: "ord-1")
        expect(order_endpoint).to receive(:cancel_order).with(symbol: "BTCUSDT", order_id: "ord-2")
        service.execute(session: session, mode: :cancel_only)
      end

      it "全 pending plan orders を cancel_plan_order で取り消す" do
        expect(order_endpoint).to receive(:cancel_plan_order).with(symbol: "BTCUSDT", order_id: "plan-1")
        service.execute(session: session, mode: :cancel_only)
      end

      it ":stopped を返す" do
        expect(service.execute(session: session, mode: :cancel_only)).to eq(:stopped)
      end

      it "close_positions / position 操作は呼ばない(ポジション保持)" do
        expect(order_endpoint).not_to receive(:close_positions)
        service.execute(session: session, mode: :cancel_only)
      end
    end

    context "pending orders が空配列" do
      it "cancel_order を 1 度も呼ばず :stopped を返す" do
        expect(order_endpoint).not_to receive(:cancel_order)
        expect(order_endpoint).not_to receive(:cancel_plan_order)
        expect(service.execute(session: session, mode: :cancel_only)).to eq(:stopped)
      end
    end

    context "orders_pending API が data 形式異常(非 Array)" do
      before { allow(order_endpoint).to receive(:orders_pending).and_return("data" => nil) }

      it "cancel_order を呼ばない / :stopped を返す(防御)" do
        expect(order_endpoint).not_to receive(:cancel_order)
        expect(service.execute(session: session, mode: :cancel_only)).to eq(:stopped)
      end
    end

    context "orderId 不在 row が混在" do
      before do
        allow(order_endpoint).to receive(:orders_pending).and_return(
          "data" => [
            { "orderId" => "ord-1" },
            { "symbol" => "BTCUSDT" } # orderId なし
          ]
        )
      end

      it "orderId のある row のみ cancel する" do
        expect(order_endpoint).to receive(:cancel_order).with(symbol: "BTCUSDT", order_id: "ord-1").once
        service.execute(session: session, mode: :cancel_only)
      end
    end

    context "個別 cancel_order が API エラーで raise した場合(部分失敗)" do
      before do
        allow(order_endpoint).to receive(:orders_pending).and_return(
          "data" => [ { "orderId" => "ord-1" }, { "orderId" => "ord-2" } ]
        )
        allow(order_endpoint).to receive(:cancel_order).with(symbol: "BTCUSDT", order_id: "ord-1")
          .and_raise(StandardError, "API rate limit")
      end

      it "logger.warn 落とし + 後続 cancel を継続(部分復旧志向)" do
        expect(order_endpoint).to receive(:cancel_order).with(symbol: "BTCUSDT", order_id: "ord-2")
        service.execute(session: session, mode: :cancel_only)
        expect(logger).to have_received(:warn).with(/cancel_order failed.*ord-1.*API rate limit/)
      end

      it "全注文 cancel が失敗しても :stopped を返す(MVP / kill-switch は best-effort)" do
        expect(service.execute(session: session, mode: :cancel_only)).to eq(:stopped)
      end
    end

    context "orders_pending 取得自体が raise した場合(致命エラー)" do
      before do
        allow(order_endpoint).to receive(:orders_pending).and_raise(StandardError, "Bitget down")
      end

      it ":halted を返す" do
        expect(service.execute(session: session, mode: :cancel_only)).to eq(:halted)
      end

      it "logger.error 落とし(機微情報 sanitize)" do
        allow(order_endpoint).to receive(:orders_pending)
          .and_raise(StandardError, "Faraday: api_key=ABC123 down")
        service.execute(session: session, mode: :cancel_only)
        expect(logger).to have_received(:error).with(/cancel_only failed.*api_key=\[FILTERED\]/)
      end
    end
  end

  describe "#execute(mode: :unknown_mode)" do
    it "ArgumentError raise(unsupported mode)" do
      expect { service.execute(session: session, mode: :unknown) }
        .to raise_error(ArgumentError, /unsupported mode.*unknown/)
    end
  end
end
