module Infrastructure
  # Bitget Public WebSocket の購読対象を表す不変 Value Object。
  # `channel` + `inst_type` + `inst_id` の組合せで購読対象を一意に識別し,
  # `to_args_hash` で Bitget WS API 仕様(`{ instType:, channel:, instId: }`)へ変換する。
  class BitgetPublicWsSubscription
    # Bitget V2 WS API で許可された `instType` 値(大文字必須)。
    INSTRUMENT_TYPES = %w[SPOT USDT-FUTURES COIN-FUTURES USDC-FUTURES].freeze

    # @param channel [String] チャネル名(例: "ticker" / "candle1m" / "books5")
    # @param inst_type [String] 商品種別(`INSTRUMENT_TYPES` のいずれか,大文字必須)
    # @param inst_id [String] 銘柄シンボル(例: "BTCUSDT")
    # @raise [ArgumentError] inst_type が許可外,または channel/inst_id が空の場合
    def initialize(channel:, inst_type:, inst_id:)
      raise ArgumentError, "inst_type must be one of #{INSTRUMENT_TYPES}" unless INSTRUMENT_TYPES.include?(inst_type)
      raise ArgumentError, "channel is required" if channel.to_s.empty?
      raise ArgumentError, "inst_id is required" if inst_id.to_s.empty?

      @channel = channel
      @inst_type = inst_type
      @inst_id = inst_id
    end

    attr_reader :channel, :inst_type, :inst_id

    # Bitget WS API 送信用の Hash 表現を返す
    #
    # @return [Hash{Symbol => String}] `{ instType:, channel:, instId: }`
    def to_args_hash
      { instType: inst_type, channel: channel, instId: inst_id }
    end

    # 等価判定(channel + inst_type + inst_id の全一致で同一とみなす)
    #
    # @param other [Object]
    # @return [Boolean]
    def ==(other)
      other.is_a?(self.class) &&
        channel == other.channel &&
        inst_type == other.inst_type &&
        inst_id == other.inst_id
    end
    alias_method :eql?, :==

    # Hash/Set のキーとして利用するための hash 値
    #
    # @return [Integer]
    def hash
      [ self.class, channel, inst_type, inst_id ].hash
    end
  end
end
