module Exchange
  # WS positions チャネルから受信したポジション情報の履歴(設計書 05_§4.3 全 23 フィールド)
  # bootstrap step 11 reconciliation 時 + WS push 受信時に新規 INSERT(履歴蓄積)
  #
  # NOTE: 設計書の `frozen` フィールドは ActiveRecord 予約語 `frozen?` と衝突するため
  # 内部カラム名は `frozen_size` を採用(Bitget API レスポンス受信時にマッピング)
  class PositionSnapshot < ApplicationRecord
    self.table_name = "exchange_position_snapshots"

    belongs_to :live_trading_session, class_name: "LiveTrading::Session"

    validates :margin_coin, presence: true, length: { maximum: 16 }
    validates :symbol, presence: true, length: { maximum: 32 }
    validates :hold_side, presence: true, length: { maximum: 8 }
    validates :total, presence: true
    validates :snapshot_at, presence: true

    # 指定 session の最新 PositionSnapshot を 1 件返す
    #
    # @param session_id [Integer] LiveTrading::Session の ID
    # @return [ActiveRecord::Relation<Exchange::PositionSnapshot>]
    def self.latest_for(session_id)
      where(live_trading_session_id: session_id).order(snapshot_at: :desc).limit(1)
    end
  end
end
