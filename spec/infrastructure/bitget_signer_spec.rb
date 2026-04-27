require "rails_helper"

RSpec.describe Infrastructure::BitgetSigner do
  let(:secret_key) { "test_secret_key" }
  let(:signer) { described_class.new(secret_key:) }

  describe "#sign" do
    subject do
      signer.sign(
        timestamp:,
        method: method_name,
        request_path:,
        query_string:,
        body:
      )
    end

    context "GETリクエストでquery_stringありbody nilの場合" do
      let(:timestamp) { 1_234_567_890_123 }
      let(:method_name) { "GET" }
      let(:request_path) { "/api/v2/mix/market/history-candles" }
      let(:query_string) { "symbol=BTCUSDT&productType=usdt-futures" }
      let(:body) { nil }

      it "timestamp + method.upcase + path + ?query で組み立てたpreHashの HMAC-SHA256 + Base64 署名を返す" do
        expected_pre_hash = "1234567890123GET/api/v2/mix/market/history-candles?symbol=BTCUSDT&productType=usdt-futures"
        expected_signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret_key, expected_pre_hash))
        expect(subject).to eq(expected_signature)
      end
    end

    context "POSTリクエストでquery_string nil bodyありの場合" do
      let(:timestamp) { 1_234_567_890_123 }
      let(:method_name) { "POST" }
      let(:request_path) { "/api/v2/mix/order/place-order" }
      let(:query_string) { nil }
      let(:body) { '{"symbol":"BTCUSDT"}' }

      it "timestamp + method.upcase + path + body で組み立てたpreHashの HMAC-SHA256 + Base64 署名を返す" do
        expected_pre_hash = '1234567890123POST/api/v2/mix/order/place-order{"symbol":"BTCUSDT"}'
        expected_signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret_key, expected_pre_hash))
        expect(subject).to eq(expected_signature)
      end
    end

    context "query_stringとbodyがいずれもnil(認証不要GET API)の場合" do
      let(:timestamp) { 1_234_567_890_123 }
      let(:method_name) { "GET" }
      let(:request_path) { "/api/v2/public/time" }
      let(:query_string) { nil }
      let(:body) { nil }

      it "timestamp + method.upcase + path のみで組み立てたpreHashの署名を返す" do
        expected_pre_hash = "1234567890123GET/api/v2/public/time"
        expected_signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret_key, expected_pre_hash))
        expect(subject).to eq(expected_signature)
      end
    end

    context "methodが小文字で渡された場合" do
      let(:timestamp) { 1_234_567_890_123 }
      let(:method_name) { "get" }
      let(:request_path) { "/api/v2/public/time" }
      let(:query_string) { nil }
      let(:body) { nil }

      it "method を upcase した値で preHash が組み立てられる" do
        expected_pre_hash = "1234567890123GET/api/v2/public/time"
        expected_signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret_key, expected_pre_hash))
        expect(subject).to eq(expected_signature)
      end
    end

    context "query_stringが空文字で渡された場合" do
      let(:timestamp) { 1_234_567_890_123 }
      let(:method_name) { "GET" }
      let(:request_path) { "/api/v2/public/time" }
      let(:query_string) { "" }
      let(:body) { nil }

      it "空文字は空のクエリとして扱い ?無しのpreHashが組み立てられる" do
        expected_pre_hash = "1234567890123GET/api/v2/public/time"
        expected_signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret_key, expected_pre_hash))
        expect(subject).to eq(expected_signature)
      end
    end
  end
end
