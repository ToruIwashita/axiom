require "rails_helper"

RSpec.describe Infrastructure::StrategyRunnerChildSpawner do
  let(:user) { User.create!(email: "spawner@example.com", name: "Spawner") }
  let(:definition) { Strategy::Definition.create!(user: user, name: "S", market_type: "futures", status: "active") }
  let(:script_body) do
    <<~RUBY
      class Sample < Domain::TradingScriptBase
        def on_tick(ctx, candle); end
      end
    RUBY
  end
  let(:revision) do
    Strategy::Revision.create!(
      strategy_definition: definition,
      revision_number: 1,
      script_content: script_body,
      script_entrypoint: "Sample",
      status: "approved",
      ast_validation_status: "passed",
      uses_live_forbidden_input: false,
      ai_filter_enabled: false,
      ai_sizing_enabled: false,
      created_by: user
    )
  end
  let(:ctx_input) { { "candle" => { "ts" => 0 }, "state" => {} } }

  let(:ipc_protocol) do
    instance_double(Infrastructure::StrategyRunnerIpcProtocol,
                    validate_request: nil,
                    validate_response: nil)
  end
  let(:resource_limiter) do
    instance_double(Infrastructure::StrategyRunnerResourceLimiter,
                    minimal_env: { "PATH" => "/usr/bin" })
  end

  let(:stdin_double) { instance_double(IO, write: nil, close: nil, closed?: false) }
  let(:stdout_double) { instance_double(IO, close: nil, closed?: false) }
  let(:stderr_double) { instance_double(IO, close: nil, closed?: false) }
  let(:wait_thread_double) { instance_double(Process::Waiter, pid: 12345, value: nil) }

  let(:successful_response) do
    {
      "schema_version" => "1.0",
      "callback" => "on_tick",
      "status" => "ok",
      "order_intents" => [],
      "logs" => [],
      "errors" => [],
      "strategy_state_diff" => { "ops" => [] }
    }
  end

  let(:spawner) do
    described_class.new(
      ipc_protocol: ipc_protocol,
      resource_limiter: resource_limiter,
      runner_script_path: "/dummy/strategy_runner_child.rb"
    )
  end

  describe "#run" do
    subject { spawner.run(callback: :on_tick, revision: revision, ctx_input: ctx_input) }

    before do
      allow(Open3).to receive(:popen3).and_return([ stdin_double, stdout_double, stderr_double, wait_thread_double ])
    end

    context "子プロセスが正常な response JSON を返す場合" do
      before do
        allow(IO).to receive(:select).and_return([ [ stdout_double ] ])
        allow(stdout_double).to receive(:read).and_return(successful_response.to_json)
      end

      it "子プロセス返却の Hash を返す" do
        result = subject
        expect(result["status"]).to eq("ok")
        expect(result["order_intents"]).to eq([])
      end

      it "ipc_protocol.validate_request / validate_response を呼ぶ(DI 動作確認)" do
        subject
        expect(ipc_protocol).to have_received(:validate_request)
        expect(ipc_protocol).to have_received(:validate_response)
      end

      it "ensure ブロックで wait_thread.value を呼び zombie を reap する" do
        expect(wait_thread_double).to receive(:value)
        subject
      end

      it "Open3.popen3 へ resource_limiter.minimal_env を渡す" do
        subject
        expect(Open3).to have_received(:popen3).with(
          { "PATH" => "/usr/bin" },
          "ruby", "/dummy/strategy_runner_child.rb",
          unsetenv_others: true
        )
      end
    end

    context "wall clock timeout を超過した場合(IO.select が nil を返す)" do
      before do
        allow(IO).to receive(:select).and_return(nil)
        allow(Process).to receive(:kill)
      end

      it "{ status: timeout, errors: [{ class: TimeoutError }] } を返す" do
        result = subject
        expect(result["status"]).to eq("timeout")
        expect(result["errors"].first["class"]).to eq("TimeoutError")
      end

      it "Process.kill('KILL', ...) を呼び wait_thread.value で reap する" do
        expect(Process).to receive(:kill).with("KILL", 12345)
        expect(wait_thread_double).to receive(:value)
        subject
      end
    end

    context "checksum 不一致時の子プロセス返却を受信する場合" do
      let(:checksum_mismatch_response) do
        {
          "schema_version" => "1.0",
          "callback" => "on_tick",
          "status" => "error",
          "order_intents" => [],
          "logs" => [],
          "errors" => [ { "class" => "ScriptIntegrityError", "message" => "checksum mismatch" } ],
          "strategy_state_diff" => { "ops" => [] }
        }
      end

      before do
        allow(IO).to receive(:select).and_return([ [ stdout_double ] ])
        allow(stdout_double).to receive(:read).and_return(checksum_mismatch_response.to_json)
      end

      it "errors に ScriptIntegrityError を含む結果Hashを返す" do
        result = subject
        expect(result["status"]).to eq("error")
        expect(result["errors"].first["class"]).to eq("ScriptIntegrityError")
      end
    end

    context "JSON parse failure: partial JSON が返る場合" do
      before do
        allow(IO).to receive(:select).and_return([ [ stdout_double ] ])
        allow(stdout_double).to receive(:read).and_return("{ partial json")
      end

      it "{ status: error, errors: [{ class: JsonParseError, raw_output: ... }] } を返す" do
        result = subject
        expect(result["status"]).to eq("error")
        expect(result["errors"].first["class"]).to eq("JsonParseError")
        expect(result["errors"].first["raw_output"]).to eq("{ partial json")
      end
    end

    context "JSON parse failure: 空文字が返る場合" do
      before do
        allow(IO).to receive(:select).and_return([ [ stdout_double ] ])
        allow(stdout_double).to receive(:read).and_return("")
      end

      it "JsonParseError を含む結果Hashを返す" do
        result = subject
        expect(result["status"]).to eq("error")
        expect(result["errors"].first["class"]).to eq("JsonParseError")
      end
    end

    context "正常パスでの ensure による wait_thread.value reap 検証" do
      before do
        allow(IO).to receive(:select).and_return([ [ stdout_double ] ])
        allow(stdout_double).to receive(:read).and_return(successful_response.to_json)
      end

      it "stdin/stdout/stderr が close され wait_thread.value が呼ばれる" do
        expect(stdin_double).to receive(:close)
        expect(wait_thread_double).to receive(:value)
        subject
      end
    end
  end
end
