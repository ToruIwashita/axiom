# Phase 4.1 + multi-agent review Agent 2 中-1 / Agent 3 中-1 反映:
# kaminari の DoS / リソース消費ガード設定.
# - default_per_page: 1 ページの既定件数(controllers の `.per(50)` 指定が優先される)
# - max_per_page: `?per_page=N` 攻撃の上限(現状 controllers から per_page params を受けないが防御深層化として)
# - max_pages: `?page=N` 巨大値攻撃の OFFSET 爆発を抑制
Kaminari.configure do |config|
  config.default_per_page = 50
  config.max_per_page = 100
  config.max_pages = 1000
end
