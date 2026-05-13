require "rails_helper"

RSpec.describe Domain::StrategyScriptAstValidatorService do
  describe "#validate" do
    subject { described_class.new.validate(script_content) }

    safe_script = <<~RUBY
      class Sample < Domain::TradingScriptBase
        def on_tick(ctx, candle)
          arr = [ 1, 2, 3 ]
          mapped = arr.map { |x| x * 2 }
          h = { a: 1 }
          h.fetch(:a, 0)
          mapped.sum
        end
      end
    RUBY

    context "純粋計算のみのscriptの場合" do
      let(:script_content) { safe_script }

      it "passed かつ uses_live_forbidden_input: false を返す" do
        expect(subject.status).to eq(:passed)
        expect(subject.uses_live_forbidden_input).to be false
      end
    end

    context "構文エラーを含むscriptの場合" do
      let(:script_content) { "class Foo; def bar; end" }

      it "status :failed と syntax を含む report を返す" do
        expect(subject.status).to eq(:failed)
        expect(subject.report).to include("syntax")
      end
    end

    context "メタプログラミング: eval を呼ぶ場合" do
      let(:script_content) { "class Foo; def bar; eval('1+1'); end; end" }

      it "status :failed を返し eval を含む report を返す" do
        expect(subject.status).to eq(:failed)
        expect(subject.report).to include("eval")
      end
    end

    %i[instance_eval module_eval class_eval __send__ define_method method_missing binding].each do |meth|
      context "メタプログラミング: #{meth} を呼ぶ場合" do
        let(:script_content) { "class Foo; def bar; obj.#{meth}; end; end" }

        it "status :failed を返す" do
          expect(subject.status).to eq(:failed)
        end
      end
    end

    context "メタプログラミング: send を呼ぶ場合" do
      let(:script_content) { "class Foo; def bar; obj.send(:foo); end; end" }

      it "status :failed を返す" do
        expect(subject.status).to eq(:failed)
      end
    end

    %i[public_send method const_get const_set].each do |meth|
      context "リフレクション: obj.#{meth} を呼ぶ場合" do
        let(:script_content) { "class Foo; def bar; obj.#{meth}(:x); end; end" }

        it "status :failed を返す" do
          expect(subject.status).to eq(:failed)
        end
      end
    end

    context "リフレクション: ObjectSpace.each_object を呼ぶ場合" do
      let(:script_content) { "ObjectSpace.each_object(Class)" }

      it "status :failed を返し ObjectSpace を含む report を返す" do
        expect(subject.status).to eq(:failed)
        expect(subject.report).to include("ObjectSpace")
      end
    end

    context "プロセス/シェル: 文字列補間内のバッククォート(DSTR 内 XSTR)" do
      let(:script_content) { 'puts "result: #{`ls`}"' }

      it "status :failed を返し shell を含む report を返す" do
        expect(subject.status).to eq(:failed)
        expect(subject.report).to include("shell")
      end
    end

    context "ファイル/IO: File.open" do
      let(:script_content) { "File.open('/etc/passwd')" }

      it "status :failed を返し File を含む report を返す" do
        expect(subject.status).to eq(:failed)
        expect(subject.report).to include("File")
      end
    end

    %w[Dir IO Pathname].each do |const|
      context "ファイル/IO: #{const} 経由のメソッド呼び出し" do
        let(:script_content) { "#{const}.read('x')" }

        it "status :failed を返す" do
          expect(subject.status).to eq(:failed)
        end
      end
    end

    context "ファイル/IO: Kernel#open(receiver-less)" do
      let(:script_content) { "open('file')" }

      it "status :failed を返し open を含む report を返す" do
        expect(subject.status).to eq(:failed)
        expect(subject.report).to include("open")
      end
    end

    context "プロセス/シェル: Process.fork" do
      let(:script_content) { "Process.fork" }

      it "status :failed を返す" do
        expect(subject.status).to eq(:failed)
      end
    end

    %w[exec system].each do |meth|
      context "プロセス/シェル: Kernel##{meth}" do
        let(:script_content) { "#{meth}('ls')" }

        it "status :failed を返す" do
          expect(subject.status).to eq(:failed)
        end
      end
    end

    context "プロセス/シェル: バッククォート" do
      let(:script_content) { "`ls`" }

      it "status :failed を返し shell を含む report を返す" do
        expect(subject.status).to eq(:failed)
        expect(subject.report).to include("shell")
      end
    end

    context "プロセス/シェル: %x{...}" do
      let(:script_content) { "%x{ls}" }

      it "status :failed を返す" do
        expect(subject.status).to eq(:failed)
      end
    end

    context "ネットワーク: Net::HTTP.get" do
      let(:script_content) { "Net::HTTP.get(URI('http://e.com'))" }

      it "status :failed を返す" do
        expect(subject.status).to eq(:failed)
      end
    end

    %w[Socket TCPSocket UDPSocket Faraday HTTP].each do |const|
      context "ネットワーク: #{const} 経由のメソッド呼び出し" do
        let(:script_content) { "#{const}.new" }

        it "status :failed を返す" do
          expect(subject.status).to eq(:failed)
        end
      end
    end

    context "ネットワーク: URI.open" do
      let(:script_content) { "URI.open('http://e.com')" }

      it "status :failed を返す" do
        expect(subject.status).to eq(:failed)
      end
    end

    %w[Thread Fiber Mutex].each do |const|
      context "並行性: #{const}.new" do
        let(:script_content) { "#{const}.new" }

        it "status :failed を返す" do
          expect(subject.status).to eq(:failed)
        end
      end
    end

    context "並行性: Process.fork(block 付き)" do
      let(:script_content) { "Process.fork { 1 }" }

      it "status :failed を返す" do
        expect(subject.status).to eq(:failed)
      end
    end

    %w[require require_relative load autoload].each do |meth|
      context "ロード系: #{meth}" do
        let(:script_content) { "#{meth} 'x'" }

        it "status :failed を返す" do
          expect(subject.status).to eq(:failed)
        end
      end
    end

    %w[Class Module].each do |const|
      context "動的コード生成: #{const}.new" do
        let(:script_content) { "#{const}.new(Object)" }

        it "status :failed を返し dynamic を含む report を返す" do
          expect(subject.status).to eq(:failed)
          expect(subject.report).to include("dynamic")
        end
      end
    end

    context "C拡張: FFI 単独参照" do
      let(:script_content) { "FFI" }

      it "status :failed を返す" do
        expect(subject.status).to eq(:failed)
      end
    end

    context "C拡張: Fiddle 単独参照" do
      let(:script_content) { "Fiddle" }

      it "status :failed を返す" do
        expect(subject.status).to eq(:failed)
      end
    end

    context "許可対象: Domain::TradingScriptBase 継承" do
      let(:script_content) { "class Foo < Domain::TradingScriptBase; end" }

      it "passed を返す" do
        expect(subject.status).to eq(:passed)
      end
    end

    context "許可対象: ctx.balance / ctx.position 等" do
      let(:script_content) do
        <<~RUBY
          class Foo < Domain::TradingScriptBase
            def on_tick(ctx, candle)
              ctx.balance
              ctx.position
              ctx.funding_rate
            end
          end
        RUBY
      end

      it "passed かつ uses_live_forbidden_input: false を返す" do
        expect(subject.status).to eq(:passed)
        expect(subject.uses_live_forbidden_input).to be false
      end
    end

    context "許可対象: 算術 / 配列 map / Hash 参照" do
      let(:script_content) do
        <<~RUBY
          class Foo < Domain::TradingScriptBase
            def on_tick(ctx, candle)
              total = (1..10).map { |x| x * 2 }.sum
              { result: total }
            end
          end
        RUBY
      end

      it "passed を返す" do
        expect(subject.status).to eq(:passed)
      end
    end

    context "live禁止入力: ctx.mark_basis を呼ぶ場合" do
      let(:script_content) do
        <<~RUBY
          class Foo < Domain::TradingScriptBase
            def on_tick(ctx, candle)
              ctx.mark_basis
            end
          end
        RUBY
      end

      it "passed かつ uses_live_forbidden_input: true を返す" do
        expect(subject.status).to eq(:passed)
        expect(subject.uses_live_forbidden_input).to be true
      end
    end

    context "live禁止入力: ctx.spot_basis を呼ぶ場合" do
      let(:script_content) do
        <<~RUBY
          class Foo < Domain::TradingScriptBase
            def on_tick(ctx, candle)
              ctx.spot_basis
            end
          end
        RUBY
      end

      it "passed かつ uses_live_forbidden_input: true を返す" do
        expect(subject.status).to eq(:passed)
        expect(subject.uses_live_forbidden_input).to be true
      end
    end

    # Phase 3 末 multi-agent review #4 反映: Symbol#to_proc 経由のリフレクションバイパス遮断
    %i[send eval __send__ public_send define_method method_missing instance_eval module_eval
       const_get const_set exec system open fork spawn exit at_exit trap to_proc].each do |sym|
      context "リフレクションバイパス: &:#{sym} (Symbol#to_proc 経由)" do
        let(:script_content) do
          <<~RUBY
            class Foo < Domain::TradingScriptBase
              def on_tick(ctx, candle)
                [ctx].each(&:#{sym})
              end
            end
          RUBY
        end

        it "failed を返す(Symbol literal が DANGEROUS_SYMBOL_LITERALS と一致)" do
          expect(subject.status).to eq(:failed)
          expect(subject.report).to include("forbidden symbol literal: :#{sym}")
        end
      end
    end

    context "Symbol literal が許可対象(`:long` 等)の場合" do
      let(:script_content) do
        <<~RUBY
          class Foo < Domain::TradingScriptBase
            def on_tick(ctx, candle)
              ctx.order.entry(side: :long, size: 0.001, order_type: :market)
            end
          end
        RUBY
      end

      it "passed を返す(:long / :market 等 通常 Symbol は許可)" do
        expect(subject.status).to eq(:passed)
      end
    end

    # Phase 3 末 multi-agent review #5 反映: fork / spawn / exit / abort / at_exit / trap 漏れ補完
    %i[fork spawn exit exit! abort at_exit trap].each do |meth|
      context "プロセス制御: #{meth}(receiver-less)" do
        let(:script_content) do
          <<~RUBY
            class Foo < Domain::TradingScriptBase
              def on_tick(ctx, candle)
                #{meth}
              end
            end
          RUBY
        end

        it "failed を返す" do
          expect(subject.status).to eq(:failed)
          expect(subject.report).to include("forbidden method: #{meth}")
        end
      end
    end

    # Phase 3 末 multi-agent review #5 反映: 任意オブジェクト復元 / DoS の漏れ補完
    %w[Marshal YAML PStore Tempfile DRb GC Kernel].each do |const|
      context "任意オブジェクト復元 / DoS: #{const} 経由のメソッド呼び出し" do
        let(:script_content) do
          <<~RUBY
            class Foo < Domain::TradingScriptBase
              def on_tick(ctx, candle)
                #{const}.load("payload")
              end
            end
          RUBY
        end

        it "failed を返す" do
          expect(subject.status).to eq(:failed)
          expect(subject.report).to include("forbidden call via constant: #{const}")
        end
      end
    end

    # Phase 3 末 multi-agent review 2 周目 高 R1 反映: :COLON3 (top-level ::Const) バイパス遮断
    %w[Marshal YAML PStore Tempfile DRb GC Kernel File Dir IO Net Socket].each do |const|
      context ":COLON3 経由 RCE バイパス: ::#{const} 経由のメソッド呼び出し" do
        let(:script_content) do
          <<~RUBY
            class Foo < Domain::TradingScriptBase
              def on_tick(ctx, candle)
                ::#{const}.load("payload")
              end
            end
          RUBY
        end

        it "failed を返す(top-level prefix によるバイパスを遮断)" do
          expect(subject.status).to eq(:failed)
          expect(subject.report).to include("forbidden call via top-level constant: ::#{const}")
        end
      end
    end

    context ":COLON3 経由 単独参照: ::Marshal" do
      let(:script_content) do
        <<~RUBY
          class Foo < Domain::TradingScriptBase
            def on_tick(ctx, candle)
              ::Marshal
            end
          end
        RUBY
      end

      it "failed を返す(top-level constant 単独参照も遮断)" do
        expect(subject.status).to eq(:failed)
        expect(subject.report).to include("forbidden top-level constant: ::Marshal")
      end
    end

    context ":COLON3 + COLON2 ネスト: ::Marshal::Foo.load" do
      let(:script_content) do
        <<~RUBY
          class Foo < Domain::TradingScriptBase
            def on_tick(ctx, candle)
              ::Marshal::FORMAT_VERSION
            end
          end
        RUBY
      end

      it "failed を返す(`:COLON3` を root に持つ COLON2 もネームスペース遮断)" do
        expect(subject.status).to eq(:failed)
        expect(subject.report).to include("forbidden namespace: Marshal::*")
      end
    end

    # Phase 3 末 multi-agent review 2 周目 中 (ii) 反映: Object/BasicObject/Module 経由のメタプロ遮断
    %w[Object BasicObject Module].each do |const|
      context "メタプロ経路: #{const}.send(:eval, ...)" do
        let(:script_content) do
          <<~RUBY
            class Foo < Domain::TradingScriptBase
              def on_tick(ctx, candle)
                #{const}.const_get(:Marshal).load("x")
              end
            end
          RUBY
        end

        it "failed を返す(#{const} を介したメタプロ経由 RCE を遮断)" do
          expect(subject.status).to eq(:failed)
          expect(subject.report).to include("forbidden call via constant: #{const}")
        end
      end
    end

    # Phase 3 末 multi-agent review 2 周目 高 R2 反映: 動的補間 Symbol (:DSYM) のリフレクションバイパス遮断
    context "動的補間 Symbol: `:\"#{"#"}{name}_call\"` (:DSYM)" do
      let(:script_content) do
        <<~RUBY
          class Foo < Domain::TradingScriptBase
            def on_tick(ctx, candle)
              name = "se"
              [ctx].each(&:"\#{name}nd")
            end
          end
        RUBY
      end

      it "failed を返す(動的 Symbol 構築は AI 生成戦略に正当用途無し)" do
        expect(subject.status).to eq(:failed)
        expect(subject.report).to include("forbidden dynamic symbol literal")
      end
    end

    # Phase 3 末 multi-agent review 2 周目 中 (ix) 反映: COLON2 経由の Marshal::Const 境界 spec
    context "COLON2 単独参照(top-level prefix 無し): Marshal::FORMAT_VERSION" do
      let(:script_content) do
        <<~RUBY
          class Foo < Domain::TradingScriptBase
            def on_tick(ctx, candle)
              Marshal::FORMAT_VERSION
            end
          end
        RUBY
      end

      it "failed を返す(Marshal:: 名前空間参照も遮断)" do
        expect(subject.status).to eq(:failed)
        expect(subject.report).to include("forbidden namespace: Marshal::*")
      end
    end

    # Phase 3 末 multi-agent review 2 周目 中 (viii) 反映: 通常 method 呼出経由(obj.to_proc)も検証
    context "obj.to_proc 経由(:CALL)も DANGEROUS_METHOD_NAMES で遮断" do
      let(:script_content) do
        <<~RUBY
          class Foo < Domain::TradingScriptBase
            def on_tick(ctx, candle)
              :send.to_proc.call(ctx)
            end
          end
        RUBY
      end

      it "failed を返す(`:CALL` 経由 `to_proc` も `DANGEROUS_METHOD_NAMES` で遮断される)" do
        expect(subject.status).to eq(:failed)
        expect(subject.report).to include("forbidden")
      end
    end
  end
end
