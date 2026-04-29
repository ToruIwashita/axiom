require "rails_helper"

RSpec.describe Infrastructure::StrategyRunnerIpcProtocol do
  let(:protocol) { described_class.new }

  let(:valid_request) do
    {
      "schema_version" => "1.0",
      "callback" => "on_tick",
      "script_content" => "class Sample < Domain::TradingScriptBase; end",
      "script_checksum" => "a" * 64,
      "script_entrypoint" => "Sample",
      "ctx_input" => {
        "candle" => { "ts" => 0, "open" => "0", "high" => "0", "low" => "0", "close" => "0" },
        "state" => {}
      }
    }
  end

  let(:valid_response) do
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

  describe "#validate_request" do
    subject { protocol.validate_request(json) }

    context "正常な request schema の場合" do
      let(:json) { valid_request }

      it "例外を raise しない" do
        expect { subject }.not_to raise_error
      end
    end

    context "request が Hash でない場合" do
      let(:json) { "not_a_hash" }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /must be a Hash/)
      end
    end

    %w[schema_version callback script_content script_checksum script_entrypoint ctx_input].each do |key|
      context "必須キー #{key} が欠落している場合" do
        let(:json) { valid_request.except(key) }

        it "ArgumentError を raise し missing キー名を含む" do
          expect { subject }.to raise_error(ArgumentError, /#{key}/)
        end
      end
    end

    context "schema_version が未対応の値の場合" do
      let(:json) { valid_request.merge("schema_version" => "0.9") }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /schema_version/)
      end
    end

    context "callback が未対応の値の場合" do
      let(:json) { valid_request.merge("callback" => "on_unknown") }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /callback/)
      end
    end

    %w[on_start on_tick on_order_event on_stop].each do |cb|
      context "callback が #{cb} の場合" do
        let(:json) { valid_request.merge("callback" => cb) }

        it "例外を raise しない" do
          expect { subject }.not_to raise_error
        end
      end
    end

    context "script_content が String でない場合" do
      let(:json) { valid_request.merge("script_content" => 123) }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /script_content/)
      end
    end

    context "script_checksum が String でない場合" do
      let(:json) { valid_request.merge("script_checksum" => nil) }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /script_checksum/)
      end
    end

    context "script_entrypoint が String でない場合" do
      let(:json) { valid_request.merge("script_entrypoint" => :Sample) }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /script_entrypoint/)
      end
    end

    context "ctx_input が Hash でない場合" do
      let(:json) { valid_request.merge("ctx_input" => "string") }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /ctx_input/)
      end
    end
  end

  describe "#validate_response" do
    subject { protocol.validate_response(json) }

    context "正常な response schema の場合" do
      let(:json) { valid_response }

      it "例外を raise しない" do
        expect { subject }.not_to raise_error
      end
    end

    context "response が Hash でない場合" do
      let(:json) { [] }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /must be a Hash/)
      end
    end

    %w[schema_version callback status order_intents logs errors strategy_state_diff].each do |key|
      context "必須キー #{key} が欠落している場合" do
        let(:json) { valid_response.except(key) }

        it "ArgumentError を raise し missing キー名を含む" do
          expect { subject }.to raise_error(ArgumentError, /#{key}/)
        end
      end
    end

    context "schema_version が未対応の値の場合" do
      let(:json) { valid_response.merge("schema_version" => "2.0") }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /schema_version/)
      end
    end

    context "callback が未対応の値の場合" do
      let(:json) { valid_response.merge("callback" => "on_unknown") }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /callback/)
      end
    end

    %w[ok timeout error].each do |st|
      context "status が #{st} の場合" do
        let(:json) { valid_response.merge("status" => st) }

        it "例外を raise しない" do
          expect { subject }.not_to raise_error
        end
      end
    end

    context "status が未対応の値の場合" do
      let(:json) { valid_response.merge("status" => "broken") }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /status/)
      end
    end

    context "order_intents が Array でない場合" do
      let(:json) { valid_response.merge("order_intents" => {}) }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /order_intents/)
      end
    end

    context "logs が Array でない場合" do
      let(:json) { valid_response.merge("logs" => "log") }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /logs/)
      end
    end

    context "errors が Array でない場合" do
      let(:json) { valid_response.merge("errors" => nil) }

      it "ArgumentError を raise し errors キー名を含む" do
        expect { subject }.to raise_error(ArgumentError, /errors/)
      end
    end

    context "strategy_state_diff が Hash でない場合" do
      let(:json) { valid_response.merge("strategy_state_diff" => []) }

      it "ArgumentError を raise する" do
        expect { subject }.to raise_error(ArgumentError, /strategy_state_diff/)
      end
    end
  end
end
