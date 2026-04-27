require "rails_helper"

RSpec.describe Infrastructure::BitgetRateLimiter do
  let(:current_time) { [ 0.0 ] }
  let(:clock) { -> { current_time[0] } }
  let(:sleep_calls) { [] }
  let(:rate_limiter) { described_class.new(clock:) }

  before do
    allow(rate_limiter).to receive(:sleep) do |seconds|
      sleep_calls << seconds
      current_time[0] += seconds
    end
  end

  describe "#acquire" do
    subject { rate_limiter.acquire(endpoint_key) }

    let(:endpoint_key) { :history_candles }

    context "レート制限内で初回呼び出しの場合" do
      it "sleep を呼ばずに即座に返却する" do
        subject
        expect(sleep_calls).to be_empty
      end
    end

    context "エンドポイント別レート(既定 20 req/sec)を1秒以内に超過した場合" do
      it "21回目で sleep が発生し最終的に成功する" do
        20.times { rate_limiter.acquire(endpoint_key) }
        rate_limiter.acquire(endpoint_key)
        expect(sleep_calls).not_to be_empty
      end
    end

    context "エンドポイント別レート超過後に補充時間が経過した場合" do
      it "sleep を経て成功し,その後の取得は再度待機なしで完了する" do
        20.times { rate_limiter.acquire(endpoint_key) }
        rate_limiter.acquire(endpoint_key)
        expect(sleep_calls).not_to be_empty

        sleep_count_before = sleep_calls.size
        current_time[0] += 5.0
        rate_limiter.acquire(endpoint_key)
        expect(sleep_calls.size).to eq(sleep_count_before)
      end
    end

    context "別のエンドポイントキーで呼び出した場合" do
      it "エンドポイント別バケットは独立しているため待機なしで取得できる" do
        20.times { rate_limiter.acquire(:history_candles) }
        rate_limiter.acquire(:history_fund_rate)
        expect(sleep_calls).to be_empty
      end
    end

    context "コンストラクタでエンドポイント別レートを上書きした場合" do
      let(:rate_limiter) { described_class.new(clock:, endpoint_rate: 5, endpoint_capacity: 5) }

      it "上書きされた制限値(5 req/sec)で挙動する" do
        5.times { rate_limiter.acquire(endpoint_key) }
        rate_limiter.acquire(endpoint_key)
        expect(sleep_calls).not_to be_empty
      end
    end
  end
end
