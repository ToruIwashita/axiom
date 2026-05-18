class AddTpSlPctToLiveTradingTrades < ActiveRecord::Migration[8.1]
  def change
    # 戦略 DSL の利確 / 損切比率(0 以上 1 未満)。
    # fill 後追いで TP/SL plan order を送信する際,fill push は order 情報のみで
    # intent の TP/SL を含まないため,エントリー時に Trade へ永続化し fill 受信時に参照する。
    # TP/SL は戦略ごとに任意指定のため nullable(未指定の Trade / 既存 Trade は NULL)。
    add_column :live_trading_trades, :tp_pct, :decimal, precision: 30, scale: 12
    add_column :live_trading_trades, :sl_pct, :decimal, precision: 30, scale: 12
  end
end
