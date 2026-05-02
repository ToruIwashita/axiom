module ApplicationServices
  # Strategy::Definition の CRUD ユースケースを提供するアプリケーション層サービス
  #
  # トランザクション境界は各メソッド = 1 トランザクション(AR 暗黙 transaction)。
  class StrategyDefinitionService
    # 新規 Definition を作成する
    #
    # @param name [String] 戦略名
    # @param market_type [String] 市場区分(例: "futures", "spot")
    # @param description [String, nil] 説明文
    # @return [Strategy::Definition] 作成された active 状態の Definition
    # @raise [ActiveRecord::RecordInvalid] 必須属性不足等のバリデーション違反
    def create(name:, market_type:, description: nil)
      Strategy::Definition.create!(
        name: name,
        description: description,
        market_type: market_type,
        status: "active"
      )
    end

    # Definition の name / description を更新する
    #
    # @param definition_id [Integer]
    # @param name [String, nil] nil なら更新しない
    # @param description [String, nil] nil なら更新しない
    # @return [Strategy::Definition] 更新後の Definition
    # @raise [ActiveRecord::RecordNotFound] definition_id の Definition が存在しない場合
    def update(definition_id:, name: nil, description: nil)
      definition = Strategy::Definition.find(definition_id)
      attrs = {}
      attrs[:name] = name unless name.nil?
      attrs[:description] = description unless description.nil?
      definition.update!(attrs) unless attrs.empty?
      definition
    end

    # Definition を archived 状態に遷移する
    #
    # @param definition_id [Integer]
    # @return [Strategy::Definition] 更新後の Definition
    # @raise [ActiveRecord::RecordNotFound]
    def archive(definition_id:)
      definition = Strategy::Definition.find(definition_id)
      definition.update!(status: "archived")
      definition
    end

    # Definition を取得する
    #
    # @param definition_id [Integer]
    # @return [Strategy::Definition]
    # @raise [ActiveRecord::RecordNotFound]
    def get(definition_id:)
      Strategy::Definition.find(definition_id)
    end

    # Definition の一覧を created_at 降順で返す
    #
    # @return [ActiveRecord::Relation<Strategy::Definition>]
    def list
      Strategy::Definition.order(created_at: :desc)
    end
  end
end
