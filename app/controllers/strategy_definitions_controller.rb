class StrategyDefinitionsController < ApplicationController
  def index
    @definitions = service.list
  end

  def show
    @definition = service.get(definition_id: params[:id].to_i)
    @revisions = revision_service.list_by_definition(definition_id: @definition.id)
  rescue ActiveRecord::RecordNotFound
    redirect_to strategy_definitions_path, alert: "Strategy::Definition not found"
  end

  def new
    @definition = Strategy::Definition.new(market_type: "futures")
  end

  def create
    @definition = service.create(
      name: params[:strategy_definition][:name],
      description: params[:strategy_definition][:description],
      market_type: params[:strategy_definition][:market_type]
    )
    redirect_to strategy_definition_path(@definition), notice: "Created"
  rescue ActiveRecord::RecordInvalid => e
    @definition = Strategy::Definition.new(definition_params_safe)
    flash.now[:alert] = e.message
    render :new, status: :unprocessable_entity
  end

  def edit
    @definition = service.get(definition_id: params[:id].to_i)
  end

  def update
    @definition = service.update(
      definition_id: params[:id].to_i,
      name: params[:strategy_definition][:name],
      description: params[:strategy_definition][:description]
    )
    redirect_to strategy_definition_path(@definition), notice: "Updated"
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = e.message
    render :edit, status: :unprocessable_entity
  end

  def destroy
    service.archive(definition_id: params[:id].to_i)
    redirect_to strategy_definitions_path, notice: "Archived"
  end

  private

  def service
    @service ||= ApplicationServices::StrategyDefinitionService.new
  end

  def revision_service
    @revision_service ||= ApplicationServices::StrategyRevisionService.new
  end

  def definition_params_safe
    params.fetch(:strategy_definition, {}).permit(:name, :description, :market_type)
  end
end
