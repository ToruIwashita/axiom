class StrategyRevisionsController < ApplicationController
  def index
    @definition = definition_service.get(definition_id: params[:strategy_definition_id].to_i)
    @revisions = service.list_by_definition(definition_id: @definition.id)
  rescue ActiveRecord::RecordNotFound
    redirect_to strategy_definitions_path, alert: "Strategy::Definition not found"
  end

  def show
    @definition = definition_service.get(definition_id: params[:strategy_definition_id].to_i)
    @revision = service.get(revision_id: params[:id].to_i)
  rescue ActiveRecord::RecordNotFound
    redirect_to strategy_definition_path(params[:strategy_definition_id]), alert: "Revision not found"
  end

  def new
    @definition = definition_service.get(definition_id: params[:strategy_definition_id].to_i)
    @revision_form = revision_form_defaults
  rescue ActiveRecord::RecordNotFound
    redirect_to strategy_definitions_path, alert: "Strategy::Definition not found"
  end

  def create
    @definition = definition_service.get(definition_id: params[:strategy_definition_id].to_i)
    @revision = service.create_draft(
      definition_id: @definition.id,
      script_content: params[:strategy_revision][:script_content],
      script_entrypoint: params[:strategy_revision][:script_entrypoint],
      ai_filter_enabled: params[:strategy_revision][:ai_filter_enabled] == "1",
      ai_filter_template_name: params[:strategy_revision][:ai_filter_template_name].presence,
      ai_filter_fail_safe: params[:strategy_revision][:ai_filter_fail_safe].presence,
      ai_filter_timeout_sec: (params[:strategy_revision][:ai_filter_timeout_sec].presence || 10).to_i,
      ai_sizing_enabled: params[:strategy_revision][:ai_sizing_enabled] == "1"
    )
    redirect_to strategy_definition_revision_path(@definition, @revision), notice: "Created"
  rescue ActiveRecord::RecordNotFound
    redirect_to strategy_definitions_path, alert: "Strategy::Definition not found"
  rescue ActiveRecord::RecordInvalid => e
    @revision_form = params[:strategy_revision].to_unsafe_h.symbolize_keys
    flash.now[:alert] = e.message
    render :new, status: :unprocessable_entity
  end

  def approve
    @definition = definition_service.get(definition_id: params[:strategy_definition_id].to_i)
    @revision = service.approve(revision_id: params[:id].to_i)
    redirect_to strategy_definition_revision_path(@definition, @revision), notice: "Approved"
  rescue ActiveRecord::RecordNotFound
    redirect_to strategy_definition_path(params[:strategy_definition_id]), alert: "Revision not found"
  rescue ApplicationServices::StrategyRevisionService::ApprovalError => e
    redirect_to strategy_definition_revision_path(params[:strategy_definition_id], params[:id]), alert: e.message
  end

  # Phase 3.4b Step 3.4-14: Revision 状態遷移 UI action
  def promote
    @definition = definition_service.get(definition_id: params[:strategy_definition_id].to_i)
    @revision = service.promote(revision_id: params[:id].to_i)
    redirect_to strategy_definition_revision_path(@definition, @revision), notice: "Promoted"
  rescue ActiveRecord::RecordNotFound
    redirect_to strategy_definition_path(params[:strategy_definition_id]), alert: "Revision not found"
  rescue Strategy::Revision::LiveForbiddenInputError => e
    redirect_to strategy_definition_revision_path(params[:strategy_definition_id], params[:id]), alert: e.message
  end

  def deprecate
    @definition = definition_service.get(definition_id: params[:strategy_definition_id].to_i)
    @revision = service.deprecate(revision_id: params[:id].to_i)
    redirect_to strategy_definition_revision_path(@definition, @revision), notice: "Deprecated"
  rescue ActiveRecord::RecordNotFound
    redirect_to strategy_definition_path(params[:strategy_definition_id]), alert: "Revision not found"
  end

  def archive
    @definition = definition_service.get(definition_id: params[:strategy_definition_id].to_i)
    @revision = service.archive(revision_id: params[:id].to_i)
    redirect_to strategy_definition_revision_path(@definition, @revision), notice: "Archived"
  rescue ActiveRecord::RecordNotFound
    redirect_to strategy_definition_path(params[:strategy_definition_id]), alert: "Revision not found"
  end

  private

  def service
    @service ||= ApplicationServices::StrategyRevisionService.new
  end

  def definition_service
    @definition_service ||= ApplicationServices::StrategyDefinitionService.new
  end

  def revision_form_defaults
    {
      script_content: "",
      script_entrypoint: "",
      ai_filter_enabled: false,
      ai_filter_template_name: "",
      ai_filter_fail_safe: "skip",
      ai_filter_timeout_sec: 10,
      ai_sizing_enabled: false
    }
  end
end
