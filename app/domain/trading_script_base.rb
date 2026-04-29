module Domain
  # AI生成戦略スクリプトの抽象基底クラス。
  #
  # サブクラスは `on_start` / `on_tick` / `on_order_event` / `on_stop` を必要に応じて override する。
  # 各 callback は `Infrastructure::StrategyRunnerChildSpawner` 経由で
  # 子プロセス単位に fork/spawn された環境で実行される(05_§1.7.1)。
  #
  # 戦略本体は statuless で,複数 callback 間の状態は `ctx.state` で扱う(05_§2.7)。
  class TradingScriptBase
    # @param params [Object, nil] 戦略固有の初期化パラメータ
    def initialize(params = nil)
      @params = params
    end

    # セッション開始時に呼ばれる。基底クラスのデフォルトは no-op。
    #
    # @param ctx [Object] 実行コンテキスト(BacktestContext / LiveContext)
    # @return [void]
    def on_start(ctx); end

    # ローソク足確定時に呼ばれる。基底クラスのデフォルトは no-op。
    #
    # @param ctx [Object] 実行コンテキスト
    # @param candle [Object] 確定したローソク足
    # @return [void]
    def on_tick(ctx, candle); end

    # 約定/取消等のイベント発生時に呼ばれる。基底クラスのデフォルトは no-op。
    #
    # @param ctx [Object] 実行コンテキスト
    # @param event [Object] イベント情報
    # @return [void]
    def on_order_event(ctx, event); end

    # セッション停止時に呼ばれる。基底クラスのデフォルトは no-op。
    #
    # @param ctx [Object] 実行コンテキスト
    # @return [void]
    def on_stop(ctx); end

    private

    attr_reader :params
  end
end
