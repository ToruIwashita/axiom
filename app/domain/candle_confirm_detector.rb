module Domain
  # WS push の candle row を順次受け取り「確定 candle」を検出する Domain サービス.
  #
  # Phase 3.4a Step 0a で Worker 責務縮小 + cross-thread race 解消のため抽出した.
  # 元: LiveTradingWorker 内 @last_candle_row + handle_candle_message + detect_confirmed_candle +
  #     build_candle_payload(WS callback thread から observe / main loop thread から reset).
  #
  # 責務:
  #   - 直前 row の memory 保持(thread-safe / Mutex 保護)
  #   - 新 row 受信時に「ts が進んでいれば直前 row を確定 payload で返す」判定
  #   - snapshot 受信時の初期 row 保持(初回確定起点設定 / 確定判定はスキップ)
  #   - WS reconnect 時の reset(次の確定判定を新 thread の最初の row から再開)
  #
  # Bitget candle row 形式: [ts(ms), open, high, low, close, base_volume, quote_volume]
  # 出典: Phase 3.3 multiple-agent review R-1 #2(snapshot 二重発注防止)+ R-2 #6(reconnect 時 reset).
  class CandleConfirmDetector
    def initialize
      @last_row = nil
      @mutex = Mutex.new
    end

    # 新 row を受信して確定判定を行う.
    # 直前 row より ts が進んでいれば直前 row を確定 payload として返す.
    # 初回(prev nil) / 同 ts(更新中)では nil を返す.
    #
    # @param row [Array] [ts(ms), open, high, low, close, base_volume, quote_volume]
    # @return [Hash, nil] 確定 payload(下記キー)/ 確定なし時は nil
    def observe(row)
      @mutex.synchronize do
        prev_row = @last_row
        @last_row = row

        return nil if prev_row.nil?

        new_ts = row[0].to_i
        prev_ts = prev_row[0].to_i
        return nil if prev_ts == new_ts

        build_payload(prev_row)
      end
    end

    # snapshot 受信時の初期 row 保持(確定判定はスキップ).
    # 次回以降の observe で確定判定の起点として使われる.
    #
    # @param row [Array] snapshot 末尾 row
    # @return [void]
    def snapshot_init(row)
      @mutex.synchronize { @last_row = row }
      nil
    end

    # 保持 row をクリア(WS reconnect 時に呼び出し).
    # reset 後の最初の observe は確定なし(prev nil 状態)に戻る.
    #
    # @return [void]
    def reset
      @mutex.synchronize { @last_row = nil }
      nil
    end

    private

    def build_payload(row)
      {
        "ts" => row[0].to_i,
        "open" => row[1],
        "high" => row[2],
        "low" => row[3],
        "close" => row[4],
        "base_volume" => row[5],
        "quote_volume" => row[6]
      }
    end
  end
end
