module Domain
  # Risk::Policy に基づく 3 種類の判定を提供する Domain サービス(設計書 05_§6.4)
  # stateless な純粋関数群(各メソッドで session を受け取り Risk::Policy を参照)
  class RiskGuardService
    # エントリー前の許可判定
    #
    # Phase 3.4-pre-2 反映: balance 引数を実際に使うセーフティネット判定追加.
    # balance ゼロ未満では entry しない(account_endpoint で取得失敗時 / 残高不足の防御).
    # これにより API contract と実装の乖離を解消する.
    #
    # @param session [LiveTrading::Session] 対象 Session(risk_policy 経由で制限値取得)
    # @param balance [BigDecimal] 現在残高. ゼロ以下の場合は entry を拒否する(Worker の
    #   fetch_initial_balance 失敗時 / 残高不足時のセーフティネット).
    # @param candidate_size [BigDecimal] エントリー候補サイズ(USDT 換算)
    # @return [Boolean] balance > 0 かつ candidate_size が max_position_exposure_usdt 以下 かつ
    #   session.leverage が max_leverage 以下なら true
    def allow_entry?(session:, balance:, candidate_size:)
      return false if balance <= 0

      policy = session.risk_policy
      candidate_size <= policy.max_position_exposure_usdt &&
        session.leverage <= policy.max_leverage
    end

    # 連続損失による cooldown 判定
    #
    # @param session [LiveTrading::Session] 対象 Session
    # @param recent_trades [Array<#loss?>] 最新降順または昇順の Trade 配列
    #   (consecutive_loss_limit 件分が連続損失なら cooldown)
    # @return [Boolean] 直近 consecutive_loss_limit 件が全て損失なら true
    def should_cooldown?(session:, recent_trades:)
      limit = session.risk_policy.consecutive_loss_limit
      return false if recent_trades.size < limit

      recent_trades.last(limit).all?(&:loss?)
    end

    # ドローダウン / 日次損失による強制停止判定
    #
    # @param session [LiveTrading::Session] 対象 Session
    # @param account_metrics [#drawdown_pct, #daily_loss_usdt] 口座指標 VO
    # @return [Boolean] DD が max_drawdown_pct 以上 または
    #   daily_loss が daily_loss_limit_usdt 以上なら true(halted 遷移)
    def should_halt?(session:, account_metrics:)
      policy = session.risk_policy
      account_metrics.drawdown_pct >= policy.max_drawdown_pct ||
        account_metrics.daily_loss_usdt >= policy.daily_loss_limit_usdt
    end
  end
end
