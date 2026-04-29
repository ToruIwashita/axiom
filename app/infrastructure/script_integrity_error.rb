module Infrastructure
  # 戦略スクリプトの SHA-256 改ざん検知時に raise される例外(05_§1.7.5).
  #
  # 子プロセスが eval 直前に親から受け取った `script_checksum` と再計算した checksum を
  # 照合し,不一致なら本例外を含むエラー Hash を IPC で親プロセスへ返却する.
  # 親プロセス側のクラス参照は本クラス,子プロセス側はインライン文字列 "ScriptIntegrityError"
  # で扱う(レビュー指摘 重要1 (B)案,02_§2.3).
  class ScriptIntegrityError < StandardError
  end
end
