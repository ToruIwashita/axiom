module Strategy
  class Definition < ApplicationRecord
    self.table_name = "strategy_definitions"

    STATUSES = %w[active archived].freeze

    enum :status, STATUSES.index_with(&:itself), prefix: :state

    has_many :revisions,
             class_name: "Strategy::Revision",
             foreign_key: :strategy_definition_id,
             inverse_of: :strategy_definition,
             dependent: :restrict_with_error

    validates :name, presence: true
    validates :market_type, presence: true
    validates :status, presence: true
  end
end
