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

    # Phase 3.4b E2E 発見: V2 で orders-plan-pending は planType ごとに分かれる.
    context "Bitget V2: orders_plan_pending を全 PLAN_TYPES で iterate" do
      before do
        allow(order_endpoint).to receive(:orders_plan_pending)
          .with(plan_type: "normal_plan", symbol: "BTCUSDT")
          .and_return("data" => [ { "orderId" => "p-normal-1" } ])
        allow(order_endpoint).to receive(:orders_plan_pending)
          .with(plan_type: "profit_loss", symbol: "BTCUSDT")
          .and_return("data" => [ { "orderId" => "p-tpsl-1" } ])
        allow(order_endpoint).to receive(:orders_plan_pending)
          .with(plan_type: "track_plan", symbol: "BTCUSDT")
          .and_return("data" => [ { "orderId" => "p-track-1" } ])
      end

      it "PLAN_TYPES 各値ごとに orders_plan_pending を呼び全 plan を cancel する" do
        expect(order_endpoint).to receive(:cancel_plan_order).with(symbol: "BTCUSDT", order_id: "p-normal-1")
        expect(order_endpoint).to receive(:cancel_plan_order).with(symbol: "BTCUSDT", order_id: "p-tpsl-1")
        expect(order_endpoint).to receive(:cancel_plan_order).with(symbol: "BTCUSDT", order_id: "p-track-1")

        expect(service.execute(session: session, mode: :cancel_only)).to eq(:stopped)

        # 各 planType の orders_plan_pending が呼ばれたことを確認(before allow stub の呼出)
        Infrastructure::BitgetOrderEndpoint::PLAN_TYPES.each do |pt|
          expect(order_endpoint).to have_received(:orders_plan_pending).with(plan_type: pt, symbol: "BTCUSDT")
        end
      end

      it "1 つの planType の取得が raise しても残 planType の処理は継続(:halted 返却)" do
        allow(order_endpoint).to receive(:orders_plan_pending)
          .with(plan_type: "profit_loss", symbol: "BTCUSDT")
          .and_raise(Infrastructure::BitgetApiError, "Parameter verification failed")

        # 残りの planType は呼ばれて cancel_plan_order が呼ばれる
        expect(order_endpoint).to receive(:cancel_plan_order).with(symbol: "BTCUSDT", order_id: "p-normal-1")
        expect(order_endpoint).to receive(:cancel_plan_order).with(symbol: "BTCUSDT", order_id: "p-track-1")

        # plan 全件 fetch 出来なかったので :halted (cancel_all_pending_plan_orders が false 返却)
        expect(service.execute(session: session, mode: :cancel_only)).to eq(:halted)
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
        expect(logger).to have_received(:error).with(/orders_pending fetch failed.*api_key=\[FILTERED\]/)
      end
    end
  end

  describe "#execute(mode: :cancel_and_market_close)" do
    before do
      allow(order_endpoint).to receive(:orders_pending).and_return("data" => [])
      allow(order_endpoint).to receive(:orders_plan_pending).and_return("data" => [])
      allow(order_endpoint).to receive(:cancel_order)
      allow(order_endpoint).to receive(:cancel_plan_order)
      allow(order_endpoint).to receive(:close_positions)
      allow(position_endpoint).to receive(:position_all).and_return("data" => [])
    end

    context "one_way_mode の場合" do
      let(:session) do
        instance_double(LiveTrading::Session,
          symbol: "BTCUSDT", margin_coin: "USDT", position_mode: "one_way_mode")
      end

      context "ポジション保有(total > 0)" do
        before do
          allow(position_endpoint).to receive(:position_all).and_return(
            "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05" } ]
          )
        end

        it "全 pending order 取消後に close_positions(hold_side: nil)を呼ぶ" do
          expect(order_endpoint).to receive(:close_positions).with(symbol: "BTCUSDT", hold_side: nil)
          service.execute(session: session, mode: :cancel_and_market_close)
        end

        it ":stopped を返す" do
          expect(service.execute(session: session, mode: :cancel_and_market_close)).to eq(:stopped)
        end
      end

      context "ポジションなし(total=0)" do
        before do
          allow(position_endpoint).to receive(:position_all).and_return(
            "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0" } ]
          )
        end

        it "close_positions を呼ばず :stopped を返す(no-op)" do
          expect(order_endpoint).not_to receive(:close_positions)
          expect(service.execute(session: session, mode: :cancel_and_market_close)).to eq(:stopped)
        end
      end
    end

    context "hedge_mode の場合" do
      let(:session) do
        instance_double(LiveTrading::Session,
          symbol: "BTCUSDT", margin_coin: "USDT", position_mode: "hedge_mode")
      end

      context "long + short 両方保有" do
        before do
          allow(position_endpoint).to receive(:position_all).and_return(
            "data" => [
              { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05" },
              { "symbol" => "BTCUSDT", "holdSide" => "short", "total" => "0.03" }
            ]
          )
        end

        it "close_positions を long と short の 2 回呼ぶ" do
          expect(order_endpoint).to receive(:close_positions).with(symbol: "BTCUSDT", hold_side: "long")
          expect(order_endpoint).to receive(:close_positions).with(symbol: "BTCUSDT", hold_side: "short")
          service.execute(session: session, mode: :cancel_and_market_close)
        end

        it ":stopped を返す" do
          expect(service.execute(session: session, mode: :cancel_and_market_close)).to eq(:stopped)
        end
      end

      context "long のみ保有 + short=0" do
        before do
          allow(position_endpoint).to receive(:position_all).and_return(
            "data" => [
              { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05" },
              { "symbol" => "BTCUSDT", "holdSide" => "short", "total" => "0" }
            ]
          )
        end

        it "close_positions を long の 1 回のみ呼ぶ" do
          expect(order_endpoint).to receive(:close_positions).with(symbol: "BTCUSDT", hold_side: "long").once
          expect(order_endpoint).not_to receive(:close_positions).with(symbol: "BTCUSDT", hold_side: "short")
          service.execute(session: session, mode: :cancel_and_market_close)
        end
      end
    end

    context "全 pending order 取消も実施される" do
      let(:session) do
        instance_double(LiveTrading::Session,
          symbol: "BTCUSDT", margin_coin: "USDT", position_mode: "one_way_mode")
      end

      before do
        allow(order_endpoint).to receive(:orders_pending).and_return(
          "data" => [ { "orderId" => "ord-1" } ]
        )
        allow(order_endpoint).to receive(:orders_plan_pending).and_return(
          "data" => [ { "orderId" => "plan-1" } ]
        )
      end

      it "通常注文 + plan 注文両方取消" do
        expect(order_endpoint).to receive(:cancel_order).with(symbol: "BTCUSDT", order_id: "ord-1")
        expect(order_endpoint).to receive(:cancel_plan_order).with(symbol: "BTCUSDT", order_id: "plan-1")
        service.execute(session: session, mode: :cancel_and_market_close)
      end
    end

    context "close_positions が raise した場合(致命エラー)" do
      let(:session) do
        instance_double(LiveTrading::Session,
          symbol: "BTCUSDT", margin_coin: "USDT", position_mode: "one_way_mode")
      end

      before do
        allow(position_endpoint).to receive(:position_all).and_return(
          "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05" } ]
        )
        allow(order_endpoint).to receive(:close_positions).and_raise(StandardError, "Bitget down")
      end

      it ":halted を返す + logger.error" do
        expect(service.execute(session: session, mode: :cancel_and_market_close)).to eq(:halted)
        expect(logger).to have_received(:error).with(/cancel_and_market_close failed.*Bitget down/)
      end
    end

    context "position_all が raise した場合(fail-safe)" do
      let(:session) do
        instance_double(LiveTrading::Session,
          symbol: "BTCUSDT", margin_coin: "USDT", position_mode: "one_way_mode")
      end

      before do
        allow(position_endpoint).to receive(:position_all).and_raise(StandardError, "API timeout")
      end

      it "close_positions(hold_side: nil)を fail-safe で呼ぶ + :stopped 返却(close は idempotent)" do
        expect(order_endpoint).to receive(:close_positions).with(symbol: "BTCUSDT", hold_side: nil)
        expect(service.execute(session: session, mode: :cancel_and_market_close)).to eq(:stopped)
        expect(logger).to have_received(:warn).with(/position_all failed.*fail-safe.*API timeout/)
      end

      it "fail-safe close_positions も raise した場合は :halted" do
        allow(order_endpoint).to receive(:close_positions).and_raise(StandardError, "Bitget down")
        expect(service.execute(session: session, mode: :cancel_and_market_close)).to eq(:halted)
      end
    end
  end

  describe "#execute(mode: :cancel_and_reduce_only)" do
    let(:clock_value) { [ 1000.0 ] }
    let(:monotonic_clock) { -> { clock_value.first } }
    let(:sleep_calls) { [] }
    let(:sleep_proc) { ->(sec) { sleep_calls << sec; clock_value[0] += sec } }
    let(:service) do
      described_class.new(
        order_endpoint: order_endpoint,
        position_endpoint: position_endpoint,
        monotonic_clock: monotonic_clock,
        sleep_proc: sleep_proc,
        logger: logger
      )
    end
    let(:session) do
      instance_double(LiveTrading::Session,
        id: 42, symbol: "BTCUSDT", margin_coin: "USDT",
        margin_mode: "isolated", position_mode: "one_way_mode")
    end
    let(:params) do
      {
        limit_offset_bps: 0,
        follow_interval_sec: 1,
        fallback_after_sec: 5,
        max_follow_iterations: 100
      }
    end

    before do
      allow(order_endpoint).to receive(:orders_pending).and_return("data" => [])
      allow(order_endpoint).to receive(:orders_plan_pending).and_return("data" => [])
      allow(order_endpoint).to receive(:cancel_order)
      allow(order_endpoint).to receive(:cancel_plan_order)
      allow(order_endpoint).to receive(:close_positions)
      allow(order_endpoint).to receive(:place_order).and_return("data" => { "orderId" => "ro-1" })
      allow(order_endpoint).to receive(:modify_order)
    end

    # 重要 3-(b): elapsed_sec の起点を冒頭で明示
    context "started_at = clock.now の起点で elapsed 判定が動作" do
      before do
        allow(position_endpoint).to receive(:position_all).and_return(
          "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0", "markPrice" => "50000" } ]
        )
      end

      it "ループ開始時刻を clock.call で取得 + elapsed が fallback_after_sec を超えたら break" do
        # position.total = 0 即終了 → place_order 呼ばれない / :stopped 返却
        expect(service.execute(session: session, mode: :cancel_and_reduce_only, params: params)).to eq(:stopped)
        expect(order_endpoint).not_to have_received(:place_order)
      end
    end

    # 重要 3-(c): execute の戻り値が :stopped / :halted Symbol で返却される(Worker 側で session.update! する責務分担)
    context "戻り値が :stopped / :halted Symbol(session.update! は service 内で行わない)" do
      before do
        allow(position_endpoint).to receive(:position_all).and_return(
          "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0", "markPrice" => "50000" } ]
        )
      end

      it "session.update! / save 等を呼ばない(session は instance_double で stub なし)" do
        # session に update!/save を stub していない → 呼ばれたら NoMethodError
        expect { service.execute(session: session, mode: :cancel_and_reduce_only, params: params) }.not_to raise_error
      end
    end

    context "client_oid 形式" do
      before do
        allow(position_endpoint).to receive(:position_all).and_return(
          "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05", "markPrice" => "50000" } ]
        )
      end

      it "client_oid は `reduce_only_close-<session.id>-<秒>-<hex16>` 形式で生成される(衝突回避)" do
        custom_params = params.merge(max_follow_iterations: 1, fallback_after_sec: 10_000)
        expect(order_endpoint).to receive(:place_order).with(
          hash_including(client_oid: a_string_matching(/\Areduce_only_close-42-\d+-[0-9a-f]{16}\z/))
        ).and_return("data" => { "orderId" => "ro-1" })
        allow(order_endpoint).to receive(:cancel_order)
        allow(order_endpoint).to receive(:close_positions)
        service.execute(session: session, mode: :cancel_and_reduce_only, params: custom_params)
      end
    end

    context "1 iteration 内でポジション close 完了(reduce_only 即時約定相当)" do
      before do
        # 1 回目: position あり / 2 回目: position closed
        responses = [
          { "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05", "markPrice" => "50000" } ] },
          { "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0", "markPrice" => "50000" } ] }
        ]
        call_count = 0
        allow(position_endpoint).to receive(:position_all) do
          response = responses[call_count] || responses.last
          call_count += 1
          response
        end
      end

      it "place_order(reduce_only)を 1 回呼び :stopped を返す" do
        expect(order_endpoint).to receive(:place_order).with(
          hash_including(
            symbol: "BTCUSDT", side: "sell", reduce_only: "yes", order_type: "limit"
          )
        ).once.and_return("data" => { "orderId" => "ro-1" })

        expect(service.execute(session: session, mode: :cancel_and_reduce_only, params: params)).to eq(:stopped)
      end

      it "follow_interval_sec で sleep する" do
        service.execute(session: session, mode: :cancel_and_reduce_only, params: params)
        expect(sleep_calls).to include(1)
      end
    end

    # 重要 3-(d): ループ条件 `(clock.call - started_at) < fallback_after_sec && iterations < max_follow_iterations` の両方適用
    context "ループ条件: 時刻ベース fallback と iterations 上限の両方適用" do
      before do
        allow(position_endpoint).to receive(:position_all).and_return(
          "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05", "markPrice" => "50000" } ]
        )
      end

      it "fallback_after_sec=2 + follow_interval_sec=1 → 2 iterations で fallback 経路に入る" do
        custom_params = params.merge(fallback_after_sec: 2, follow_interval_sec: 1, max_follow_iterations: 100)
        # fallback で close_positions が呼ばれる
        expect(order_endpoint).to receive(:close_positions).with(symbol: "BTCUSDT", hold_side: nil)
        service.execute(session: session, mode: :cancel_and_reduce_only, params: custom_params)
      end

      it "max_follow_iterations=2 + fallback_after_sec=10000 → 2 iterations で iterations 上限到達して fallback 経路" do
        custom_params = params.merge(max_follow_iterations: 2, follow_interval_sec: 1, fallback_after_sec: 10_000)
        expect(order_endpoint).to receive(:close_positions).with(symbol: "BTCUSDT", hold_side: nil)
        service.execute(session: session, mode: :cancel_and_reduce_only, params: custom_params)
      end
    end

    # 重要 3-(a): fallback 直前に reduce_only 指値を必ずキャンセル(設計書原文)
    context "fallback 直前に reduce_only 指値をキャンセル" do
      before do
        allow(position_endpoint).to receive(:position_all).and_return(
          "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05", "markPrice" => "50000" } ]
        )
      end

      it "place_order で得た orderId を fallback で cancel_order する" do
        custom_params = params.merge(max_follow_iterations: 1, fallback_after_sec: 10_000)
        expect(order_endpoint).to receive(:cancel_order).with(symbol: "BTCUSDT", order_id: "ro-1")
        expect(order_endpoint).to receive(:close_positions)
        service.execute(session: session, mode: :cancel_and_reduce_only, params: custom_params)
      end

      it "place_order が一度も成功していない場合は cancel_order を skip(防御)" do
        # 初回 position が即 total=0 → place_order に到達しない
        allow(position_endpoint).to receive(:position_all).and_return(
          "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0" } ]
        )
        expect(order_endpoint).not_to receive(:cancel_order).with(hash_including(order_id: anything))
        expect(service.execute(session: session, mode: :cancel_and_reduce_only, params: params)).to eq(:stopped)
      end
    end

    context "2 iteration 目以降は modify_order で価格改定" do
      before do
        allow(position_endpoint).to receive(:position_all).and_return(
          "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05", "markPrice" => "50000" } ]
        )
      end

      it "1 回目 place_order / 2 回目以降 modify_order" do
        custom_params = params.merge(max_follow_iterations: 3, fallback_after_sec: 10_000)
        expect(order_endpoint).to receive(:place_order).once.and_return("data" => { "orderId" => "ro-1" })
        expect(order_endpoint).to receive(:modify_order).with(
          hash_including(symbol: "BTCUSDT", order_id: "ro-1")
        ).twice
        expect(order_endpoint).to receive(:cancel_order)
        expect(order_endpoint).to receive(:close_positions)
        service.execute(session: session, mode: :cancel_and_reduce_only, params: custom_params)
      end
    end

    context "fallback close_positions が成功した場合" do
      before do
        allow(position_endpoint).to receive(:position_all).and_return(
          "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05", "markPrice" => "50000" } ]
        )
      end

      it ":stopped を返す" do
        custom_params = params.merge(max_follow_iterations: 1, fallback_after_sec: 10_000)
        expect(service.execute(session: session, mode: :cancel_and_reduce_only, params: custom_params)).to eq(:stopped)
      end
    end

    context "fallback close_positions が raise した場合" do
      before do
        allow(position_endpoint).to receive(:position_all).and_return(
          "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05", "markPrice" => "50000" } ]
        )
        allow(order_endpoint).to receive(:close_positions).and_raise(StandardError, "Bitget down")
      end

      it ":halted を返す + logger.error" do
        custom_params = params.merge(max_follow_iterations: 1, fallback_after_sec: 10_000)
        expect(service.execute(session: session, mode: :cancel_and_reduce_only, params: custom_params)).to eq(:halted)
        expect(logger).to have_received(:error).with(/cancel_and_reduce_only.*close_positions.*Bitget down/)
      end
    end

    context "hedge_mode で long position の場合" do
      let(:session) do
        instance_double(LiveTrading::Session,
          id: 42, symbol: "BTCUSDT", margin_coin: "USDT",
          margin_mode: "isolated", position_mode: "hedge_mode")
      end

      before do
        allow(position_endpoint).to receive(:position_all).and_return(
          "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05", "markPrice" => "50000" } ]
        )
      end

      it "place_order に trade_side: 'close' + hold_side で fallback close_positions" do
        custom_params = params.merge(max_follow_iterations: 1, fallback_after_sec: 10_000)
        expect(order_endpoint).to receive(:place_order).with(
          hash_including(side: "sell", trade_side: "close", reduce_only: "yes")
        ).and_return("data" => { "orderId" => "ro-1" })
        expect(order_endpoint).to receive(:close_positions).with(symbol: "BTCUSDT", hold_side: "long")
        service.execute(session: session, mode: :cancel_and_reduce_only, params: custom_params)
      end
    end

    context "ループ途中で position が消えた場合 + reduce_only 指値が残存" do
      before do
        responses = [
          { "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05", "markPrice" => "50000" } ] },
          { "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0", "markPrice" => "50000" } ] }
        ]
        call_count = 0
        allow(position_endpoint).to receive(:position_all) do
          response = responses[call_count] || responses.last
          call_count += 1
          response
        end
      end

      it "ループ途中の :stopped return 前にも reduce_only 指値を必ず cancel する(残存指値の反対方向約定リスク回避)" do
        expect(order_endpoint).to receive(:place_order).and_return("data" => { "orderId" => "ro-1" })
        expect(order_endpoint).to receive(:cancel_order).with(symbol: "BTCUSDT", order_id: "ro-1")
        expect(service.execute(session: session, mode: :cancel_and_reduce_only, params: params)).to eq(:stopped)
      end
    end

    context "markPrice が nil / 不正値の場合(fail-safe)" do
      before do
        allow(position_endpoint).to receive(:position_all).and_return(
          "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05", "markPrice" => nil } ]
        )
      end

      it "追従ループを abort して fallback close_positions に直行" do
        expect(order_endpoint).not_to receive(:place_order)
        expect(order_endpoint).to receive(:close_positions)
        service.execute(session: session, mode: :cancel_and_reduce_only, params: params)
        expect(logger).to have_received(:warn).with(/markPrice missing\/invalid.*falling back/)
      end
    end

    context "modify_order が raise した場合(部分失敗)" do
      before do
        allow(position_endpoint).to receive(:position_all).and_return(
          "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05", "markPrice" => "50000" } ]
        )
        call_count = 0
        allow(order_endpoint).to receive(:modify_order) do
          call_count += 1
          raise StandardError, "modify failed" if call_count == 1
        end
      end

      it "logger.warn 落とし + 新規 place_order を再実行" do
        custom_params = params.merge(max_follow_iterations: 3, fallback_after_sec: 10_000)
        # 1 回目 place + 2 回目 modify(raise) + 再 place + 3 回目 modify
        expect(order_endpoint).to receive(:place_order).at_least(:twice).and_return("data" => { "orderId" => "ro-1" })
        allow(order_endpoint).to receive(:cancel_order)
        allow(order_endpoint).to receive(:close_positions)
        service.execute(session: session, mode: :cancel_and_reduce_only, params: custom_params)
        expect(logger).to have_received(:warn).with(/modify_order failed/)
      end
    end

    # Phase 3 末 multi-agent review #7 反映:
    # modify 失敗 → cancel も失敗した場合に新規 place_order を skip して二重発注を回避.
    context "modify_order 失敗後 cancel_order も失敗した場合(二重発注リスク回避)" do
      before do
        allow(position_endpoint).to receive(:position_all).and_return(
          "data" => [ { "symbol" => "BTCUSDT", "holdSide" => "long", "total" => "0.05", "markPrice" => "50000" } ]
        )
        # 初回 place_order は成功 → existing_order_id を返す
        # 2 回目以降は modify_order を試行 → raise → cancel_order も raise
        place_count = 0
        allow(order_endpoint).to receive(:place_order) do
          place_count += 1
          { "data" => { "orderId" => "ro-#{place_count}" } }
        end
        allow(order_endpoint).to receive(:modify_order).and_raise(StandardError, "modify failed")
        allow(order_endpoint).to receive(:cancel_order).and_raise(StandardError, "cancel also failed")
        allow(order_endpoint).to receive(:close_positions)
      end

      it "cancel 失敗時は新規 place_order を呼ばず logger.error + 既存 order_id 維持で次 iteration へ" do
        custom_params = params.merge(max_follow_iterations: 3, fallback_after_sec: 10_000)
        # place_order は初回 1 回のみ呼ばれる(2 回目以降の修正経路で skip される)
        service.execute(session: session, mode: :cancel_and_reduce_only, params: custom_params)
        expect(order_endpoint).to have_received(:place_order).once
        expect(logger).to have_received(:error)
          .with(/cancel failed before place_order.*skipping new reduce_only place/).at_least(:once)
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
