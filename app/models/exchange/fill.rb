module Exchange
  class Fill < ApplicationRecord
    self.table_name = "exchange_fills"

    belongs_to :exchange_order, class_name: "Exchange::Order"

    validates :bitget_fill_id, presence: true, uniqueness: true, length: { maximum: 64 }
    validates :price, presence: true, numericality: { greater_than: 0 }
    validates :size, presence: true, numericality: { greater_than: 0 }
    validates :fee, presence: true
    validates :fee_coin, presence: true, length: { maximum: 16 }
    validates :filled_at, presence: true
  end
end
