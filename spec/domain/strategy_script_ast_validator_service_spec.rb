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
  end
end
