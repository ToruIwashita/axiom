module Api
  module V1
    # Phase 4.3 namespace 試行錯誤の名残として残存している空 controller.
    #
    # routes 未マップで使用なし(実体は app/controllers/api/v1/backtesting/comparisons_controller.rb).
    # zeitwerk autoload がファイル名に対応する class 定義を期待するため,削除許可
    # 取得までの暫定として最小空 class 定義のみ維持する.
    # 後続 commit で `git rm` 予定.
    class BacktestingComparisonsController < ApplicationController
    end
  end
end
