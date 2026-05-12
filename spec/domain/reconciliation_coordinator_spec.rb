require "rails_helper"

RSpec.describe Domain::ReconciliationCoordinator do
  let(:logger) { instance_double(Logger, warn: nil, info: nil, error: nil, debug: nil) }
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

    it "5 件の reconcile_* を順序で呼ぶ(plan 系は PLAN_TYPES 全 iterate)" do
      expect(order_endpoint).to receive(:orders_pending).with(symbol: "BTCUSDT").ordered
      Infrastructure::BitgetOrderEndpoint::PLAN_TYPES.each do |pt|
        expect(order_endpoint).to receive(:orders_plan_pending)
          .with(plan_type: pt, symbol: "BTCUSDT").ordered
      end
      Infrastructure::BitgetOrderEndpoint::PLAN_TYPES.each do |pt|
        expect(order_endpoint).to receive(:orders_plan_history)
          .with(hash_including(plan_type: pt, symbol: "BTCUSDT")).ordered
      end
      expect(position_endpoint).to receive(:position_all)
        .with(margin_coin: "USDT", symbol: "BTCUSDT").ordered
      expect(account_endpoint).to receive(:fill_history)
        .with(hash_including(symbol: "BTCUSDT")).ordered

      coordinator.run_for_bootstrap(session)
    end

    # evaluate_outcome の振り分けは private のため run_for_bootstrap 経由で検証する.
    context "結果集約" do
      context "全成功(全 reconcile が non-nil 返却)" do
        it "raise しない / warn しない" do
          expect { coordinator.run_for_bootstrap(session) }.not_to raise_error
          expect(logger).not_to have_received(:warn)
        end
      end

      context "1 件失敗(部分失敗 1/5)" do
        before do
          allow(order_endpoint).to receive(:orders_plan_pending).and_raise(StandardError, "boom")
        end

        it "raise しない / warn する" do
          expect { coordinator.run_for_bootstrap(session) }.not_to raise_error
          expect(logger).to have_received(:warn)
            .with(/reconciliation partially failed \(1\/5\).*orders_plan_pending/)
        end
      end

      context "4 件失敗(部分失敗 4/5)" do
        before do
          allow(order_endpoint).to receive(:orders_pending).and_raise(StandardError, "boom")
          allow(order_endpoint).to receive(:orders_plan_pending).and_raise(StandardError, "boom")
          allow(order_endpoint).to receive(:orders_plan_history).and_raise(StandardError, "boom")
          allow(position_endpoint).to receive(:position_all).and_raise(StandardError, "boom")
        end

        it "raise しない / warn する" do
          expect { coordinator.run_for_bootstrap(session) }.not_to raise_error
          expect(logger).to have_received(:warn).with(/reconciliation partially failed \(4\/5\)/)
        end
      end

      context "全失敗" do
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
  end

  describe "#run_after_reconnect" do
    it "session.start_reconciling! は呼ばない(状態遷移なし)" do
      coordinator.run_after_reconnect(session)
      expect(session).not_to have_received(:start_reconciling!)
    end

    it "5 件の reconcile_* を順序で呼ぶ(bootstrap と同じ / plan 系は PLAN_TYPES iterate)" do
      expect(order_endpoint).to receive(:orders_pending).with(symbol: "BTCUSDT").ordered
      Infrastructure::BitgetOrderEndpoint::PLAN_TYPES.each do |pt|
        expect(order_endpoint).to receive(:orders_plan_pending)
          .with(plan_type: pt, symbol: "BTCUSDT").ordered
      end
      Infrastructure::BitgetOrderEndpoint::PLAN_TYPES.each do |pt|
        expect(order_endpoint).to receive(:orders_plan_history)
          .with(hash_including(plan_type: pt, symbol: "BTCUSDT")).ordered
      end
      expect(position_endpoint).to receive(:position_all)
        .with(margin_coin: "USDT", symbol: "BTCUSDT").ordered
      expect(account_endpoint).to receive(:fill_history)
        .with(hash_including(symbol: "BTCUSDT")).ordered

      coordinator.run_after_reconnect(session)
    end

    it "全失敗でも raise しない(running 維持 / 部分復旧志向)" do
      allow(order_endpoint).to receive(:orders_pending).and_raise(StandardError, "down")
      allow(order_endpoint).to receive(:orders_plan_pending).and_raise(StandardError, "down")
      allow(order_endpoint).to receive(:orders_plan_history).and_raise(StandardError, "down")
      allow(position_endpoint).to receive(:position_all).and_raise(StandardError, "down")
      allow(account_endpoint).to receive(:fill_history).and_raise(StandardError, "down")
      expect { coordinator.run_after_reconnect(session) }.not_to raise_error
    end

    context "個別 reconcile_* 失敗時の logger.warn" do
      it "orders_pending 失敗で warn 落とし + 後続継続" do
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

  # R-8-3 #C-4: failed 判定明示化(nil / false / :failed sentinel を失敗扱い).
  describe "FAILURE_SENTINELS による failed 判定" do
    context "false / :failed sentinel が混在(plan 系は raise でしか失敗化できないので位置の異なる 2 endpoint で検証)" do
      before do
        # orders_pending は単純呼出 → false 戻りで sentinel 検出
        allow(order_endpoint).to receive(:orders_pending).and_return(false)
        # position_all も単純呼出 → :failed 戻りで sentinel 検出
        allow(position_endpoint).to receive(:position_all).and_return(:failed)
      end

      it "false / :failed も failure 扱いで warn する(部分失敗 2/5)" do
        expect { coordinator.run_for_bootstrap(session) }.not_to raise_error
        expect(logger).to have_received(:warn).with(/reconciliation partially failed \(2\/5\)/)
      end
    end
  end

  # Phase 3.4b E2E 発見: Bitget paper trading は fill-history 未対応 → paptrading_enabled 時 skip.
  describe "paptrading_enabled モードでの fill_history skip" do
    let(:coordinator) do
      described_class.new(
        order_endpoint: order_endpoint,
        position_endpoint: position_endpoint,
        account_endpoint: account_endpoint,
        paptrading_enabled: true,
        logger: logger
      )
    end

    it "fill_history endpoint を呼ばずに :skipped を返す(成功扱い)" do
      expect(account_endpoint).not_to receive(:fill_history)
      expect { coordinator.run_for_bootstrap(session) }.not_to raise_error
      expect(logger).to have_received(:info).with(/reconcile_fill_history skipped \(paptrading mode/)
      # :skipped は FAILURE_SENTINELS に含まれないので部分失敗にならない
      expect(logger).not_to have_received(:warn)
    end
  end
end
