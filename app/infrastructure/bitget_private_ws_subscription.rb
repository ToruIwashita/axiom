module Infrastructure
  # Bitget Private WebSocket の購読対象を表す不変 Value Object。
  # `channel` + `inst_type` + (`inst_id` or `coin`) の組合せで購読対象を一意に識別し,
  # `to_args_hash` で Bitget WS API 仕様へ変換する。
  #
  # Bitget V2 仕様の channel 別パラメータ:
  # - symbol-scoped(orders / orders-algo / fill / positions / positions-history):
  #   `{ instType:, channel:, instId: }`
  #   (orders 系は instId=symbol / positions 系は instId="default" で全 symbol 購読)
  # - account-scoped(account / account-crossed / account-isolated):
  #   `{ instType:, channel:, coin: }`(coin="default" で全 coin 購読)
  #
  # BitgetPublicWsSubscription と構造は同等だが,別クラスとして実装することで
  # Public/Private の型分離を保証する(等価判定でも別クラスは false 扱い)。
  class BitgetPrivateWsSubscription
    # Bitget V2 WS API で許可された `instType` 値(大文字必須)。
    INSTRUMENT_TYPES = %w[SPOT USDT-FUTURES COIN-FUTURES USDC-FUTURES].freeze

    # @param channel [String] チャネル名(例: "orders" / "fill" / "positions" / "account")
    # @param inst_type [String] 商品種別(`INSTRUMENT_TYPES` のいずれか,大文字必須)
    # @param inst_id [String, nil] 銘柄シンボル or "default"(symbol-scoped channel 用)
    # @param coin [String, nil] coin or "default"(account-scoped channel 用)
    # @raise [ArgumentError] inst_type が許可外,channel が空,または inst_id/coin の双方が指定/未指定の場合
    def initialize(channel:, inst_type:, inst_id: nil, coin: nil)
      raise ArgumentError, "inst_type must be one of #{INSTRUMENT_TYPES}" unless INSTRUMENT_TYPES.include?(inst_type)
      raise ArgumentError, "channel is required" if channel.to_s.empty?
      if inst_id.to_s.empty? && coin.to_s.empty?
        raise ArgumentError, "either inst_id or coin is required"
      end
      if !inst_id.to_s.empty? && !coin.to_s.empty?
        raise ArgumentError, "inst_id and coin are mutually exclusive"
      end

      @channel = channel
      @inst_type = inst_type
      @inst_id = inst_id
      @coin = coin
    end

    attr_reader :channel, :inst_type, :inst_id, :coin

    # Bitget WS API 送信用の Hash 表現を返す
    #
    # @return [Hash{Symbol => String}] symbol-scoped: `{ instType:, channel:, instId: }` /
    #   account-scoped: `{ instType:, channel:, coin: }`
    def to_args_hash
      base = { instType: inst_type, channel: channel }
      coin ? base.merge(coin: coin) : base.merge(instId: inst_id)
    end

    # 等価判定(channel + inst_type + (inst_id or coin) の全一致 + 同一クラスで同一とみなす)
    #
    # @param other [Object]
    # @return [Boolean]
    def ==(other)
      other.is_a?(self.class) &&
        channel == other.channel &&
        inst_type == other.inst_type &&
        inst_id == other.inst_id &&
        coin == other.coin
    end
    alias_method :eql?, :==

    # Hash/Set のキーとして利用するための hash 値
    #
    # @return [Integer]
    def hash
      [ self.class, channel, inst_type, inst_id, coin ].hash
    end
  end
end
