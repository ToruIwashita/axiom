module Infrastructure
  class BitgetRateLimiter
    DEFAULT_GLOBAL_CAPACITY = 6_000
    DEFAULT_GLOBAL_REFILL_RATE = 6_000.0 / 60.0
    DEFAULT_ENDPOINT_CAPACITY = 20
    DEFAULT_ENDPOINT_REFILL_RATE = 20.0

    # @param clock [#call] 単調増加時刻を返すクロージャ(テスト用に DI 可能)
    # @param global_capacity [Integer] グローバルバケット容量(既定 6000)
    # @param global_refill_rate [Float] グローバル補充レート tokens/sec(既定 100.0)
    # @param endpoint_capacity [Integer] エンドポイント別バケット容量(既定 20)
    # @param endpoint_rate [Float] エンドポイント別補充レート tokens/sec(既定 20.0)
    def initialize(
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      global_capacity: DEFAULT_GLOBAL_CAPACITY,
      global_refill_rate: DEFAULT_GLOBAL_REFILL_RATE,
      endpoint_capacity: DEFAULT_ENDPOINT_CAPACITY,
      endpoint_rate: DEFAULT_ENDPOINT_REFILL_RATE
    )
      @clock = clock
      @global_bucket = Bucket.new(capacity: global_capacity, refill_rate: global_refill_rate, clock:)
      @endpoint_capacity = endpoint_capacity
      @endpoint_rate = endpoint_rate
      @endpoint_buckets = {}
      @mutex = Mutex.new
    end

    # トークンを1つ取得する。グローバル + エンドポイント別 両方のバケットを消費し,
    # 不足時は補充されるまで sleep して待機する(Mutex で排他制御)。
    #
    # @param endpoint_key [Symbol] エンドポイント識別キー(例: :history_candles)
    # @return [void]
    def acquire(endpoint_key)
      loop do
        wait_time = mutex.synchronize do
          endpoint_bucket = endpoint_bucket_for(endpoint_key)
          global_bucket.refill
          endpoint_bucket.refill
          if global_bucket.available? && endpoint_bucket.available?
            global_bucket.consume
            endpoint_bucket.consume
            0.0
          else
            [ global_bucket.wait_time, endpoint_bucket.wait_time ].max
          end
        end
        return if wait_time.zero?
        sleep(wait_time)
      end
    end

    private

    attr_reader :clock, :global_bucket, :endpoint_capacity, :endpoint_rate, :endpoint_buckets, :mutex

    def endpoint_bucket_for(endpoint_key)
      endpoint_buckets[endpoint_key] ||= Bucket.new(
        capacity: endpoint_capacity,
        refill_rate: endpoint_rate,
        clock: clock
      )
    end

    class Bucket
      def initialize(capacity:, refill_rate:, clock:)
        @capacity = capacity.to_f
        @refill_rate = refill_rate.to_f
        @clock = clock
        @tokens = capacity.to_f
        @last_refill_at = clock.call
      end

      def refill
        now = clock.call
        elapsed = now - last_refill_at
        @tokens = [ tokens + elapsed * refill_rate, capacity ].min
        @last_refill_at = now
      end

      def available?
        tokens >= 1.0
      end

      def consume
        @tokens -= 1.0
      end

      def wait_time
        return 0.0 if available?
        (1.0 - tokens) / refill_rate
      end

      private

      attr_reader :capacity, :refill_rate, :clock, :tokens, :last_refill_at
    end
    private_constant :Bucket
  end
end
