require "rails_helper"

RSpec.describe ApplicationServices::AiInvocationLogService do
  let(:service) { described_class.new }

  def create_log(attrs = {})
    Integration::AiInvocationLog.create!({
      context_type: "entry_filter",
      prompt: "test prompt",
      response: "test response",
      latency_ms: 100,
      status: "success"
    }.merge(attrs))
  end

  describe "#list" do
    subject { service.list(filters: filters) }

    let(:filters) { {} }

    context "filter なしの場合" do
      let!(:log_old) { create_log(latency_ms: 50, created_at: 2.hours.ago) }
      let!(:log_new) { create_log(latency_ms: 200, created_at: 1.hour.ago) }

      it "全件を created_at 降順で返す" do
        expect(subject.to_a).to eq([ log_new, log_old ])
      end
    end

    context "context_type フィルタの場合" do
      let!(:entry_filter_log) { create_log(context_type: "entry_filter") }
      let!(:script_log) { create_log(context_type: "script_generation") }
      let(:filters) { { context_type: "entry_filter" } }

      it "指定 context_type のみ返す" do
        expect(subject.to_a).to eq([ entry_filter_log ])
      end
    end

    context "status フィルタの場合" do
      let!(:success_log) { create_log(status: "success") }
      let!(:timeout_log) { create_log(status: "timeout") }
      let(:filters) { { status: "timeout" } }

      it "指定 status のみ返す" do
        expect(subject.to_a).to eq([ timeout_log ])
      end
    end

    context "filter 値が空文字の場合(Strong Parameters の present? チェック)" do
      let!(:log) { create_log }
      let(:filters) { { context_type: "", status: "" } }

      it "filter は適用されず全件返す" do
        expect(subject.to_a).to eq([ log ])
      end
    end

    # multi-agent review Agent 2 中-2 反映: enum allow-list 違反時の Fail Fast 検証
    context "filter 値が enum CONTEXT_TYPES 外の場合" do
      let(:filters) { { context_type: "unknown_type" } }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /context_type must be one of/)
      end
    end

    context "filter 値が enum STATUSES 外の場合" do
      let(:filters) { { status: "unknown_status" } }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /status must be one of/)
      end
    end

    context "kaminari .page chain との互換性" do
      before { 3.times { create_log } }

      it "ActiveRecord::Relation を返し .page(N).per(M) chain が動作する" do
        relation = subject.page(1).per(2)
        expect(relation.size).to eq(2)
        expect(relation.total_count).to eq(3)
      end
    end
  end

  describe "#get" do
    subject { service.get(log_id: log_id) }

    context "存在する ID を指定した場合" do
      let!(:log) { create_log }
      let(:log_id) { log.id }

      it "該当レコードを返す" do
        expect(subject).to eq(log)
      end
    end

    context "存在しない ID を指定した場合" do
      let(:log_id) { 999_999 }

      it "ActiveRecord::RecordNotFound を raise する" do
        expect { subject }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "#aggregate" do
    subject { service.aggregate }

    context "ログ 0 件の場合" do
      it "全 7 context_type について total=0 / success_rate=0.0 を返す" do
        expect(subject.keys).to match_array(Integration::AiInvocationLog::CONTEXT_TYPES)
        Integration::AiInvocationLog::CONTEXT_TYPES.each do |ct|
          stats = subject[ct]
          expect(stats[:total_count]).to eq(0)
          expect(stats[:success_count]).to eq(0)
          expect(stats[:failure_count]).to eq(0)
          expect(stats[:success_rate]).to eq(0.0)
          expect(stats[:avg_latency]).to eq(0)
          expect(stats[:p50_latency]).to eq(0)
          expect(stats[:p99_latency]).to eq(0)
        end
      end
    end

    context "entry_filter に成功 3 件 / 失敗 1 件,他 context_type 0 件の場合" do
      before do
        create_log(context_type: "entry_filter", status: "success", latency_ms: 100)
        create_log(context_type: "entry_filter", status: "success", latency_ms: 200)
        create_log(context_type: "entry_filter", status: "success", latency_ms: 300)
        create_log(context_type: "entry_filter", status: "timeout", latency_ms: 400)
      end

      it "entry_filter の集計値が正しい" do
        stats = subject["entry_filter"]
        expect(stats[:total_count]).to eq(4)
        expect(stats[:success_count]).to eq(3)
        expect(stats[:failure_count]).to eq(1)
        expect(stats[:success_rate]).to eq(75.0)
        expect(stats[:avg_latency]).to eq(250)
      end

      it "他 context_type は total=0" do
        (Integration::AiInvocationLog::CONTEXT_TYPES - [ "entry_filter" ]).each do |ct|
          expect(subject[ct][:total_count]).to eq(0)
        end
      end
    end

    context "1 件のみ存在する場合の percentile" do
      before { create_log(context_type: "entry_filter", latency_ms: 150) }

      it "p50 / p99 ともに唯一の値を返す" do
        stats = subject["entry_filter"]
        expect(stats[:p50_latency]).to eq(150)
        expect(stats[:p99_latency]).to eq(150)
      end
    end

    context "100 件存在する場合の percentile" do
      before do
        100.times { |i| create_log(context_type: "entry_filter", latency_ms: i + 1) }
      end

      it "p50 が中央値付近 / p99 が上位値を返す" do
        stats = subject["entry_filter"]
        expect(stats[:p50_latency]).to be_between(50, 51)
        expect(stats[:p99_latency]).to be_between(99, 100)
      end
    end

    # peer AI レビュー 中-2 反映: SQL group by で N+1 を起こさず少数 query で完結
    context "SQL クエリ数(N+1 検証)" do
      before do
        Integration::AiInvocationLog::CONTEXT_TYPES.each do |ct|
          create_log(context_type: ct)
        end
      end

      it "context_type 7 件 × 3 SQL ではなく 3 SQL 程度で完結する" do
        query_count = 0
        counter = ->(_name, _start, _finish, _id, payload) {
          query_count += 1 unless payload[:name] == "SCHEMA"
        }
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
          subject
        end
        # group by counts + average + grouped pluck = 3 SQL 程度(7 context_type 全件 SQL = 21 SQL ではないこと)
        expect(query_count).to be <= 5
      end
    end
  end
end
