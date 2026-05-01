module Backtesting
  class Trade < ApplicationRecord
    self.table_name = "backtesting_trades"

    SIDES = %w[long short].freeze

    belongs_to :run,
               class_name: "Backtesting::Run",
               foreign_key: :backtesting_run_id

    validates :side, presence: true, inclusion: { in: SIDES }
    validates :entry_at, presence: true
    validates :exit_at, presence: true
    validates :entry_price, presence: true
    validates :exit_price, presence: true
    validates :quantity, presence: true
    validates :pnl, presence: true
    validate :exit_at_on_or_after_entry_at

    private

    def exit_at_on_or_after_entry_at
      return if entry_at.blank? || exit_at.blank?

      errors.add(:exit_at, "must be on or after entry_at") unless exit_at >= entry_at
    end
  end
end
