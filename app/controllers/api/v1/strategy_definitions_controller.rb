module Api
  module V1
    class StrategyDefinitionsController < ApplicationController
      include PayloadHelpers

      def index
        definitions = service.list
        render json: { definitions: definitions.map { |d| definition_payload(d) } }
      end

      def show
        definition = service.get(definition_id: params[:id].to_i)
        render json: definition_payload(definition)
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      end

      def create
        definition = service.create(
          name: params[:name],
          description: params[:description],
          market_type: params[:market_type]
        )
        render json: definition_payload(definition), status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def update
        definition = service.update(
          definition_id: params[:id].to_i,
          name: params[:name],
          description: params[:description]
        )
        render json: definition_payload(definition)
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def service
        @service ||= ApplicationServices::StrategyDefinitionService.new
      end
    end
  end
end
