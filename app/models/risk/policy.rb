module Risk
  class Policy < ApplicationRecord
    self.table_name = "risk_policies"

    # Bitget USDT-M 先物のレバレッジ上限。
    # https://www.bitget.com/api-doc/contract/account/Get-Single-Symbol-Leverage で取得可能な
    # シンボル別最大レバレッジは銘柄により 50/20 等で頭打ちになるが,
    # Risk::Policy 単体での上限としては Bitget 全体の最大値 125 を採用する。
    # 銘柄別上限との照合は Phase 2/3 の Domain::RiskGuardService で行う。
    BITGET_USDT_FUTURES_MAX_LEVERAGE = 125

    # name の uniqueness: 設計書 §6.3 で大文字小文字区別の指定なし。
    # 運用合意が取れるまで case_sensitive はデフォルト(true)とし,
    # case-insensitive uniqueness が必要となった時点で `case_sensitive: false` に変更する判断ポイントを残す。
    validates :name, presence: true, uniqueness: true
    validates :max_drawdown_pct,
              presence: true,
              numericality: { greater_than: 0, less_than_or_equal_to: 100 }
    validates :consecutive_loss_limit,
              presence: true,
              numericality: { only_integer: true, greater_than_or_equal_to: 1 }
    validates :max_position_exposure_usdt,
              presence: true,
              numericality: { greater_than: 0 }
    validates :max_leverage,
              presence: true,
              numericality: {
                only_integer: true,
                greater_than_or_equal_to: 1,
                less_than_or_equal_to: BITGET_USDT_FUTURES_MAX_LEVERAGE
              }
    validates :cooldown_minutes,
              presence: true,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :daily_loss_limit_usdt,
              presence: true,
              numericality: { greater_than: 0 }
  end
end
