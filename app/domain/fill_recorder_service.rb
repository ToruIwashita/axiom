require "bigdecimal"

module Domain
  # WS fill push を起点に Exchange::Fill を作成し LiveTrading::Trade を集計する Domain サービス
  # (設計書 02_§2.3 e).
  #
  # Bitget API I/O は持たず DB レコードのみを扱う stateless サービス.
  # record_fill_from_push は内部で LiveTrading::Session.transaction を張る.
  #
  # Trade 遷移の責務境界: 本サービスは Trade を entering → open / closing → closed まで遷移させる.
  # 発注側遷移 pending → entering / open → closing は Domain::OrderLifecycleService の責務.
  class FillRecorderService
    # @param logger [Logger] 親 Order 未発見等の警告出力先
    def initialize(logger: Rails.logger)
      @logger = logger
    end

    # WS fill push の 1 row を処理し Exchange::Fill を作成,全約定時に Trade を集計する.
    #
    # 親 Order を orderId(= bitget_order_id)で突合し,Exchange::Fill を bitget_fill_id(= tradeId)で
    # 冪等に作成する.親 Order の fill 合計数量が Order.size に達したら全約定とみなし Trade を集計する
    # (orders push の filled ステータスには依存しない).
    #
    # @param push_row [Hash] fill push の 1 row(orderId / tradeId / price / baseVolume / feeDetail / cTime)
    # @param session [LiveTrading::Session] 対象セッション
    # @return [void]
    def record_fill_from_push(push_row, session:)
      LiveTrading::Session.transaction do
        order = Exchange::Order.find_by(bitget_order_id: push_row["orderId"])
        if order.nil?
          logger.warn(
            "[FillRecorderService] fill push: parent order not found " \
            "(orderId=#{push_row["orderId"]} tradeId=#{push_row["tradeId"]}); skip"
          )
          next
        end

        create_fill(order, push_row)
        aggregate_trade(order) if fully_filled?(order)
      end
    end

    private

    attr_reader :logger

    # bitget_fill_id 冪等で Exchange::Fill を作成する(既存 fill なら作成 skip).
    def create_fill(order, push_row)
      Exchange::Fill.find_or_create_by!(bitget_fill_id: push_row["tradeId"]) do |fill|
        fill.exchange_order = order
        fill.price = push_row["price"]
        fill.size = push_row["baseVolume"]
        fill.fee = total_fee(push_row)
        fill.fee_coin = fee_coin(push_row)
        fill.filled_at = Time.at(push_row["cTime"].to_i / 1000.0).utc
      end
    end

    # 親 Order の fill 合計数量が Order.size に達したか(全約定判定 / orders push 非依存).
    def fully_filled?(order)
      fills_of(order).sum(BigDecimal("0"), &:size) >= order.size
    end

    # 全約定した Order に応じて Trade を集計する.
    # エントリー Order なら entering → open,決済 Order なら closing → closed.
    def aggregate_trade(order)
      trade = order.live_trading_trade
      if order.trade_side_open?
        aggregate_entry(trade, order)
      else
        aggregate_close(trade, order)
      end
    end

    # エントリー fill 集計: 加重平均 entry_price で Trade を open に遷移する(entering 時のみ / 冪等ガード).
    def aggregate_entry(trade, order)
      return unless trade.state_entering?

      fills = fills_of(order)
      trade.mark_open!(
        entry_price: weighted_average_price(fills),
        entry_at: fills.map(&:filled_at).max
      )
    end

    # 決済 fill 集計: 加重平均 exit_price + realized_pnl で Trade を closed に遷移する(closing 時のみ / 冪等ガード).
    def aggregate_close(trade, order)
      return unless trade.state_closing?

      fills = fills_of(order)
      exit_price = weighted_average_price(fills)
      trade.mark_closed!(
        exit_price: exit_price,
        exit_at: fills.map(&:filled_at).max,
        realized_pnl: realized_pnl(trade, exit_price)
      )
    end

    # realized_pnl = (long: exit-entry / short: entry-exit) * quantity - 総 fee(設計書 02_§2.3 b-2).
    def realized_pnl(trade, exit_price)
      diff = trade.side_long? ? (exit_price - trade.entry_price) : (trade.entry_price - exit_price)
      (diff * trade.quantity) - total_trade_fee(trade)
    end

    # 当該 Trade に属する全 Order の全 fill の fee 合計(エントリー Order + 決済 Order).
    def total_trade_fee(trade)
      order_ids = Exchange::Order.where(live_trading_trade_id: trade.id).pluck(:id)
      Exchange::Fill.where(exchange_order_id: order_ids).sum(:fee)
    end

    # fill 群の加重平均価格 Σ(price * size) / Σ(size).
    def weighted_average_price(fills)
      total_size = fills.sum(BigDecimal("0"), &:size)
      fills.sum(BigDecimal("0")) { |fill| fill.price * fill.size } / total_size
    end

    def fills_of(order)
      Exchange::Fill.where(exchange_order_id: order.id).to_a
    end

    # feeDetail(配列 / 各要素 feeCoin + totalFee)から fee 合計を算出する.
    def total_fee(push_row)
      Array(push_row["feeDetail"]).sum(BigDecimal("0")) { |detail| BigDecimal(detail["totalFee"].to_s) }
    end

    # feeDetail の先頭要素の feeCoin(通常 1 fill の手数料は単一通貨).
    def fee_coin(push_row)
      detail = Array(push_row["feeDetail"]).first
      detail && detail["feeCoin"]
    end
  end
end
