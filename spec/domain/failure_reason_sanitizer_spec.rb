require "rails_helper"

RSpec.describe Domain::FailureReasonSanitizer do
  describe ".sanitize" do
    subject { described_class.sanitize(input) }

    context "key=value 形式" do
      let(:input) { "Faraday error: api_key=ABC123XYZ failed" }

      it "credentials を [FILTERED] に置換する" do
        expect(subject).to eq("Faraday error: api_key=[FILTERED] failed")
      end
    end

    context "JSON 形式" do
      let(:input) { '{"api_key": "ABC123", "other": "value"}' }

      it "value 部分のみ [FILTERED] に置換する(key 名は保持)" do
        expect(subject).to eq('{"api_key": "[FILTERED]", "other": "value"}')
      end
    end

    context "JSON 形式 camelCase" do
      let(:input) { '{"apiKey": "ABC", "secretKey": "XYZ"}' }

      it "apiKey / secretKey も対応" do
        expect(subject).to eq('{"apiKey": "[FILTERED]", "secretKey": "[FILTERED]"}')
      end
    end

    context "passphrase / signature / token 形式" do
      let(:input) { "passphrase=secret123 token=abc456 signature=xyz789" }

      it "全種類対応" do
        expect(subject).to include("passphrase=[FILTERED]")
        expect(subject).to include("token=[FILTERED]")
        expect(subject).to include("signature=[FILTERED]")
      end
    end

    context "別フィールド名(authorization / bearer / x-api-key / private_key)" do
      let(:input) { "authorization=Bearer xyz bearer=abc x-api-key=key123 private_key=PEM" }

      it "全種類対応" do
        expect(subject).to include("authorization=[FILTERED]")
        expect(subject).to include("bearer=[FILTERED]")
        expect(subject).to include("x-api-key=[FILTERED]")
        expect(subject).to include("private_key=[FILTERED]")
      end
    end

    context "Bitget HTTP header 形式" do
      let(:input) { "ACCESS-KEY=abc ACCESS-SIGN=xyz ACCESS-PASSPHRASE=pass" }

      it "ACCESS-KEY / ACCESS-SIGN / ACCESS-PASSPHRASE 対応" do
        expect(subject).to include("ACCESS-KEY=[FILTERED]")
        expect(subject).to include("ACCESS-SIGN=[FILTERED]")
        expect(subject).to include("ACCESS-PASSPHRASE=[FILTERED]")
      end
    end

    context "JSON value 内 escape された quote" do
      let(:input) { '{"api_key": "ABC\\"DEF"}' }

      it "全 value をマスク(後半残らない)" do
        expect(subject).to eq('{"api_key": "[FILTERED]"}')
      end
    end

    context "URL parameter 形式" do
      let(:input) { "?api_key=ABC123&other=value" }

      it "& を終端と認識して切り分ける" do
        expect(subject).to eq("?api_key=[FILTERED]&other=value")
      end
    end

    context "通常の日本語テキスト(誤マスク防止)" do
      it "passphrase は秘密です は不変(= 前置き必須)" do
        expect(described_class.sanitize("passphrase は秘密です")).to eq("passphrase は秘密です")
      end

      it "設計書の signature について追記する は不変" do
        expect(described_class.sanitize("設計書の signature について追記する"))
          .to eq("設計書の signature について追記する")
      end
    end

    context "ws_disconnected reason 形式は影響なし" do
      let(:input) { "ws_disconnected: public_ws=true private_ws=false" }

      it "対象 key 名でないため不変" do
        expect(subject).to eq("ws_disconnected: public_ws=true private_ws=false")
      end
    end

    context "nil 入力" do
      let(:input) { nil }

      it "空文字を返す(raise しない)" do
        expect(subject).to eq("")
      end
    end
  end
end
