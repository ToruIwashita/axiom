module ApplicationServices
  # `Integration::AiInvocationLog` の一覧 / 詳細 / 集計を提供するアプリケーションサービス.
  #
  # 設計書: 02_§2.3 / 03_§2.2.
  # peer AI レビュー反映:
  #   - 中-2 反映: `#aggregate` を SQL `group(:context_type, :status).count` + `group(:context_type).average(:latency_ms)`
  #     ベースで 3 SQL 程度に削減(従来案の 7 context_type × 3 SQL = 21 SQL を回避).
  #   - 新-中-1 反映: percentile 計算は memory ロードのままだが,大規模化時(N >> 10_000)の window function 化を
  #     Phase 5b 引き継ぎ事項として 02_§9 に記録済.
  class AiInvocationLogService
    # 一覧取得(filter + 時系列降順).
    #
    # @param filters [Hash] フィルタ条件.
    #   - `:context_type` [String, nil] CONTEXT_TYPES のいずれか.空文字 / nil 時は無効.
    #   - `:status` [String, nil] STATUSES のいずれか.空文字 / nil 時は無効.
    # @return [ActiveRecord::Relation] kaminari `.page(N).per(M)` を chain 可能.
    def list(filters: {})
      scope = Integration::AiInvocationLog.order(created_at: :desc)
      scope = scope.where(context_type: filters[:context_type]) if filters[:context_type].present?
      scope = scope.where(status: filters[:status]) if filters[:status].present?
      scope
    end

    # 詳細取得.
    #
    # @param log_id [Integer] 取得対象 ID.
    # @return [Integration::AiInvocationLog]
    # @raise [ActiveRecord::RecordNotFound] 指定 ID が存在しない場合.
    def get(log_id:)
      Integration::AiInvocationLog.find(log_id)
    end

    # context_type 別集計.
    #
    # @return [Hash{String => Hash}] 全 7 context_type を key に,以下を value とする Hash:
    #   - `:total_count` [Integer]
    #   - `:success_count` [Integer]
    #   - `:failure_count` [Integer]
    #   - `:success_rate` [Float] %値(0.0〜100.0).
    #   - `:avg_latency` [Integer] ms 単位.
    #   - `:p50_latency` [Integer] ms 単位.
    #   - `:p99_latency` [Integer] ms 単位.
    def aggregate
      counts_by_ctype_status = Integration::AiInvocationLog.group(:context_type, :status).count
      avg_latency_by_ctype = Integration::AiInvocationLog.group(:context_type).average(:latency_ms)
      latencies_by_ctype = Integration::AiInvocationLog
                             .pluck(:context_type, :latency_ms)
                             .group_by(&:first)
                             .transform_values { |arr| arr.map(&:last).sort }

      Integration::AiInvocationLog::CONTEXT_TYPES.index_with do |ct|
        compute_stats(ct, counts_by_ctype_status, avg_latency_by_ctype, latencies_by_ctype[ct] || [])
      end
    end

    private

    def compute_stats(context_type, counts_by_ctype_status, avg_latency_by_ctype, latencies)
      total = Integration::AiInvocationLog::STATUSES.sum { |st| counts_by_ctype_status[[ context_type, st ]] || 0 }
      success = counts_by_ctype_status[[ context_type, "success" ]] || 0
      avg = avg_latency_by_ctype[context_type]&.to_f&.round(0) || 0
      {
        total_count: total,
        success_count: success,
        failure_count: total - success,
        success_rate: total.zero? ? 0.0 : (success.to_f / total * 100).round(2),
        avg_latency: avg,
        p50_latency: percentile(latencies, 0.50),
        p99_latency: percentile(latencies, 0.99)
      }
    end

    # latencies は事前に sort 済前提.
    # @return [Integer]
    def percentile(sorted_latencies, ratio)
      return 0 if sorted_latencies.empty?

      idx = (sorted_latencies.size * ratio).floor.clamp(0, sorted_latencies.size - 1)
      sorted_latencies[idx]
    end
  end
end
