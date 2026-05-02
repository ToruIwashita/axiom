module Api
  module V1
    class MarketDataController < ApplicationController
      def sync
        results = service.sync(
          symbol: params[:symbol],
          data_types: Array(params[:data_types]),
          granularity: params[:granularity],
          period_from: Time.parse(params[:period_from]),
          period_to: Time.parse(params[:period_to])
        )
        render json: { results: results }
      rescue ArgumentError => e
        render json: { error: e.message }, status: :bad_request
      end

      private

      def service
        @service ||= ApplicationServices::MarketDataSyncService.new
      end
    end
  end
end
