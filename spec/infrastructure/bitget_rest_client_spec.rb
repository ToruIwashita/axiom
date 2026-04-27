require "rails_helper"

RSpec.describe Infrastructure::BitgetRestClient do
  let(:api_key) { "test_api_key" }
  let(:secret_key) { "test_secret_key" }
  let(:passphrase) { "test_passphrase" }
  let(:rate_limiter) { instance_double(Infrastructure::BitgetRateLimiter, acquire: nil) }
  let(:base_url) { "https://api.bitget.com" }
  let(:paptrading_enabled) { false }
  let(:client) do
    described_class.new(
      api_key:,
      secret_key:,
      passphrase:,
      paptrading_enabled:,
      rate_limiter:,
      base_url:,
      retry_options: { max: 3, interval: 0, backoff_factor: 1 }
    )
  end

  describe "#request" do
    let(:path) { "/api/v2/public/time" }

    context "auth: false で公開APIを呼ぶ場合" do
      subject { client.request(:get, path) }

      before do
        stub_request(:get, "#{base_url}#{path}")
          .to_return(
            status: 200,
            body: { code: "00000", data: { serverTime: "1234567890123" } }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "認証ヘッダなしでリクエストし JSON パース済みの Hash を返す" do
        result = subject
        expect(result).to include("code" => "00000")
        expect(WebMock).to have_requested(:get, "#{base_url}#{path}").with { |req|
          req.headers["Access-Key"].nil? && req.headers["Access-Sign"].nil?
        }
      end
    end

    context "auth: true で認証必要APIを呼ぶ場合" do
      subject { client.request(:get, path, params: { symbol: "BTCUSDT" }, auth: true) }

      let(:path) { "/api/v2/common/trade-rate" }

      before do
        stub_request(:get, "#{base_url}#{path}")
          .with(query: { symbol: "BTCUSDT" })
          .to_return(
            status: 200,
            body: { code: "00000", data: {} }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "ACCESS-KEY / ACCESS-SIGN / ACCESS-TIMESTAMP / ACCESS-PASSPHRASE が付与される" do
        subject
        expect(WebMock).to have_requested(:get, "#{base_url}#{path}")
          .with(query: { symbol: "BTCUSDT" }) { |req|
            req.headers["Access-Key"] == api_key &&
              !req.headers["Access-Sign"].to_s.empty? &&
              !req.headers["Access-Timestamp"].to_s.empty? &&
              req.headers["Access-Passphrase"] == passphrase
          }
      end
    end

    context "リトライ可エラー code が返る場合" do
      subject { client.request(:get, path) }

      before do
        stub_request(:get, "#{base_url}#{path}").to_return(
          {
            status: 200,
            body: { code: "45001", msg: "Unknown error" }.to_json,
            headers: { "Content-Type" => "application/json" }
          },
          {
            status: 200,
            body: { code: "00000", data: {} }.to_json,
            headers: { "Content-Type" => "application/json" }
          }
        )
      end

      it "自動リトライして最終的に成功する" do
        expect(subject["code"]).to eq("00000")
        expect(WebMock).to have_requested(:get, "#{base_url}#{path}").twice
      end
    end

    context "HTTP 429 が返る場合" do
      subject { client.request(:get, path) }

      before do
        stub_request(:get, "#{base_url}#{path}").to_return(
          { status: 429, body: "" },
          {
            status: 200,
            body: { code: "00000", data: {} }.to_json,
            headers: { "Content-Type" => "application/json" }
          }
        )
      end

      it "自動リトライして最終的に成功する" do
        subject
        expect(WebMock).to have_requested(:get, "#{base_url}#{path}").twice
      end
    end

    context "リトライ不可エラー code=40001 の場合" do
      subject { client.request(:get, path) }

      before do
        stub_request(:get, "#{base_url}#{path}").to_return(
          status: 200,
          body: { code: "40001", msg: "ACCESS_KEY cannot be empty" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      it "BitgetApiError を raise し code 属性を保持する" do
        expect { subject }.to raise_error(Infrastructure::BitgetApiError) { |error|
          expect(error.code).to eq("40001")
          expect(error.response_body).to include("code" => "40001")
        }
      end
    end

    context "code が予期しない値(99999)の場合" do
      subject { client.request(:get, path) }

      before do
        stub_request(:get, "#{base_url}#{path}").to_return(
          status: 200,
          body: { code: "99999", msg: "unexpected" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      it "BitgetApiError を raise する" do
        expect { subject }.to raise_error(Infrastructure::BitgetApiError) { |error|
          expect(error.code).to eq("99999")
        }
      end
    end

    context "paptrading_enabled: true の場合" do
      subject { client.request(:get, path) }

      let(:paptrading_enabled) { true }

      before do
        stub_request(:get, "#{base_url}#{path}")
          .to_return(
            status: 200,
            body: { code: "00000", data: {} }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "paptrading: '1' ヘッダが付与される" do
        subject
        expect(WebMock).to have_requested(:get, "#{base_url}#{path}")
          .with(headers: { "Paptrading" => "1" })
      end
    end

    context "rate_limiter#acquire がリクエスト前に呼ばれる場合" do
      subject { client.request(:get, path, endpoint_key: :history_candles) }

      before do
        stub_request(:get, "#{base_url}#{path}")
          .to_return(
            status: 200,
            body: { code: "00000", data: {} }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "endpoint_key を引数として acquire が呼ばれる" do
        subject
        expect(rate_limiter).to have_received(:acquire).with(:history_candles)
      end
    end
  end
end
