module Infrastructure
  # 戦略実行子プロセスのリソース制限と環境変数遮断を司るクラス。
  #
  # 子プロセス起動前に親側で `minimal_env` を `Open3.popen3(env, ..., unsetenv_others: true)` に
  # 渡し,子プロセス内で `apply_limits!` 相当の `setrlimit` を実行することで多層防御を構成する
  # (05_§1.6.4 / §1.7.2).
  #
  # 本タスクではレビュー指摘(重要1 (B)案)に従い子プロセス側の setrlimit は
  # `lib/strategy_runner_child.rb` 内にインライン定義する.本クラスは親プロセス側で
  # `minimal_env` を提供する責務を持ちつつ,setrlimit 自体の API も親側テスト/将来再利用のため
  # 維持する.
  class StrategyRunnerResourceLimiter
    DEFAULT_CPU_SECONDS = 1
    DEFAULT_MEMORY_BYTES = 256 * 1024 * 1024
    MINIMAL_ENV_KEYS = %w[PATH LANG].freeze

    # 子プロセス内でリソース制限を適用する(05_§1.7.2)
    #
    # @return [void]
    # @note macOS では `Process::RLIMIT_AS` が完全には機能しない場合がある(Darwin 仕様).
    #   spec では `Process.setrlimit` の呼び出し検証で代替し,本格的な enforcement は
    #   Linux 本番運用で確認する(02_§注意事項).
    def apply_limits!
      Process.setrlimit(Process::RLIMIT_CPU, DEFAULT_CPU_SECONDS)
      Process.setrlimit(Process::RLIMIT_AS, DEFAULT_MEMORY_BYTES) if rlimit_as_supported?
    end

    # 子プロセスへ渡す最小環境変数 Hash を返す(macOS 開発時の `ENV` 遮断,05_§1.6.4)
    #
    # @return [Hash{String => String}] PATH / LANG のみを含む環境変数 Hash
    def minimal_env
      ENV.to_h.slice(*MINIMAL_ENV_KEYS)
    end

    private

    def rlimit_as_supported?
      defined?(Process::RLIMIT_AS)
    end
  end
end
