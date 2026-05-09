require "rails_helper"

RSpec.describe Domain::ReconciliationCoordinator do
  let(:logger) { instance_double(Logger, warn: nil) }
  let(:order_endpoint) { instance_double(Infrastructure::BitgetOrderEndpoint) }
  let(:position_endpoint) { instance_double(Infrastructure::BitgetPositionEndpoint) }
  let(:account_endpoint) { instance_double(Infrastructure::BitgetAccountEndpoint) }
  let(:coordinator) do
    described_class.new(
      order_endpoint: order_endpoint,
      position_endpoint: position_endpoint,
      account_endpoint: account_endpoint,
      logger: logger
    )
  end
  let(:session) do
    instance_double(LiveTrading::Session, symbol: "BTCUSDT", margin_coin: "USDT", start_reconciling!: true)
  end

  before do
    allow(order_endpoint).to receive(:orders_pending).and_return("data" => [])
    allow(order_endpoint).to receive(:orders_plan_pending).and_return("data" => [])
    allow(order_endpoint).to receive(:orders_plan_history).and_return("data" => [])
    allow(position_endpoint).to receive(:position_all).and_return("data" => [])
    allow(account_endpoint).to receive(:fill_history).and_return("data" => [])
  end

  describe "#run_for_bootstrap" do
    it "session.start_reconciling! を呼ぶ" do
      coordinator.run_for_bootstrap(session)
      expect(session).to have_received(:start_reconciling!)
    end

    it "5 件の reconcile_* を順序で呼ぶ(orders_pending → plan_pending → plan_history → position_all → fill_history)" do
      expect(order_endpoint).to receive(:orders_pending).with(symbol: "BTCUSDT").ordered.and_return("data" => [])
      expect(order_endpoint).to receive(:orders_plan_pending).with(symbol: "BTCUSDT").ordered.and_return("data" => [])
      expect(order_endpoint).to receive(:orders_plan_history)
        .with(hash_including(symbol: "BTCUSDT")).ordered.and_return("data" => [])
      expect(position_endpoint).to receive(:position_all)
        .with(margin_coin: "USDT", symbol: "BTCUSDT").ordered.and_return("data" => [])
      expect(account_endpoint).to receive(:fill_history)
        .with(hash_including(symbol: "BTCUSDT")).ordered.and_return("data" => [])

      coordinator.run_for_bootstrap(session)
    end

    context "全失敗時" do
      before do
        allow(order_endpoint).to receive(:orders_pending).and_raise(StandardError, "down")
        allow(order_endpoint).to receive(:orders_plan_pending).and_raise(StandardError, "down")
        allow(order_endpoint).to receive(:orders_plan_history).and_raise(StandardError, "down")
        allow(position_endpoint).to receive(:position_all).and_raise(StandardError, "down")
        allow(account_endpoint).to receive(:fill_history).and_raise(StandardError, "down")
      end

      it "raise StandardError(reconciliation all failed)" do
        expect { coordinator.run_for_bootstrap(session) }
          .to raise_error(StandardError, /reconciliation all failed/)
      end
    end
  end

  describe "#run_after_reconnect" do
    it "session.start_reconciling! は呼ばない(状態遷移なし)" do
      coordinator.run_after_reconnect(session)
      expect(session).not_to have_received(:start_reconciling!)
    end

    it "5 件の reconcile_* を呼ぶ" do
      coordinator.run_after_reconnect(session)
      expect(order_endpoint).to have_received(:orders_pending).with(symbol: "BTCUSDT")
      expect(order_endpoint).to have_received(:orders_plan_pending).with(symbol: "BTCUSDT")
      expect(order_endpoint).to have_received(:orders_plan_history).with(hash_including(symbol: "BTCUSDT"))
      expect(position_endpoint).to have_received(:position_all).with(margin_coin: "USDT", symbol: "BTCUSDT")
      expect(account_endpoint).to have_received(:fill_history).with(hash_including(symbol: "BTCUSDT"))
    end
  end

  describe "#evaluate_outcome" do
    context "全成功" do
      let(:results) do
        {
          orders_pending: { "data" => [] },
          orders_plan_pending: { "data" => [] },
          orders_plan_history: { "data" => [] },
          position_all: { "data" => [] },
          fill_history: { "data" => [] }
        }
      end

      it "raise しない / warn しない" do
        expect { coordinator.evaluate_outcome(results) }.not_to raise_error
        expect(logger).not_to have_received(:warn)
      end
    end

    context "1 件失敗(部分失敗)" do
      let(:results) do
        {
          orders_pending: { "data" => [] },
          orders_plan_pending: nil,
          orders_plan_history: { "data" => [] },
          position_all: { "data" => [] },
          fill_history: { "data" => [] }
        }
      end

      it "raise しない / warn する(部分失敗 1/5)" do
        expect { coordinator.evaluate_outcome(results) }.not_to raise_error
        expect(logger).to have_received(:warn)
          .with(/reconciliation partially failed \(1\/5\).*orders_plan_pending/)
      end
    end

    context "4 件失敗(部分失敗)" do
      let(:results) do
        {
          orders_pending: nil,
          orders_plan_pending: nil,
          orders_plan_history: nil,
          position_all: nil,
          fill_history: { "data" => [] }
        }
      end

      it "raise しない / warn する(部分失敗 4/5)" do
        expect { coordinator.evaluate_outcome(results) }.not_to raise_error
        expect(logger).to have_received(:warn).with(/reconciliation partially failed \(4\/5\)/)
      end
    end

    context "全失敗" do
      let(:results) do
        {
          orders_pending: nil, orders_plan_pending: nil, orders_plan_history: nil,
          position_all: nil, fill_history: nil
        }
      end

      it "raise StandardError(reconciliation all failed)" do
        expect { coordinator.evaluate_outcome(results) }
          .to raise_error(StandardError, /reconciliation all failed/)
      end
    end

    context "false / :failed sentinel(R-8-3 #C-4)" do
      let(:results) do
        {
          orders_pending: false,
          orders_plan_pending: :failed,
          orders_plan_history: { "data" => [] },
          position_all: { "data" => [] },
          fill_history: { "data" => [] }
        }
      end

      it "false / :failed も failure 扱いで warn する" do
        expect { coordinator.evaluate_outcome(results) }.not_to raise_error
        expect(logger).to have_received(:warn).with(/reconciliation partially failed \(2\/5\)/)
      end
    end
  end

  describe "個別 reconcile_* 失敗時の logger.warn" do
    it "orders_pending 失敗で warn 落とし + nil 返却(後続継続)" do
      allow(order_endpoint).to receive(:orders_pending).and_raise(StandardError, "API down")
      coordinator.run_after_reconnect(session)
      expect(logger).to have_received(:warn).with(/reconcile_orders_pending failed.*API down/)
    end

    it "fill_history 失敗で warn 落とし(機微情報 sanitize)" do
      allow(account_endpoint).to receive(:fill_history)
        .and_raise(StandardError, "Faraday error: api_key=ABC123 failed")
      coordinator.run_after_reconnect(session)
      expect(logger).to have_received(:warn).with(/api_key=\[FILTERED\]/)
    end
  end
end
