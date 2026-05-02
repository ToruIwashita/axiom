module Api
  module V1
    class StrategyRevisionsController < ApplicationController
      include PayloadHelpers

      def index
        revisions = service.list_by_definition(definition_id: params[:strategy_definition_id].to_i)
        render json: { revisions: revisions.map { |r| revision_payload(r) } }
      end

      def show
        revision = service.get(revision_id: params[:id].to_i)
        render json: revision_payload(revision)
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      end

      def create
        revision = service.create_draft(
          definition_id: params[:strategy_definition_id].to_i,
          script_content: params[:script_content],
          script_entrypoint: params[:script_entrypoint],
          ai_filter_enabled: params[:ai_filter_enabled] || false,
          ai_filter_template_name: params[:ai_filter_template_name],
          ai_filter_fail_safe: params[:ai_filter_fail_safe],
          ai_filter_timeout_sec: params[:ai_filter_timeout_sec] || 10,
          ai_sizing_enabled: params[:ai_sizing_enabled] || false
        )
        render json: revision_payload(revision), status: :created
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def approve
        revision = service.approve(revision_id: params[:id].to_i)
        render json: revision_payload(revision)
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      rescue ApplicationServices::StrategyRevisionService::ApprovalError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def service
        @service ||= ApplicationServices::StrategyRevisionService.new
      end
    end
  end
end
