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

    context "ハイフン prefix が前置された Bitget HTTP header 形式(X-access-key 等)" do
      let(:input) { "X-access-key=ABC123 some-prefix-access-sign=xyz" }

      it "prefix のハイフンが境界として認識され credential が漏洩しない" do
        expect(subject).to include("access-key=[FILTERED]")
        expect(subject).to include("access-sign=[FILTERED]")
        expect(subject).not_to include("ABC123")
        expect(subject).not_to include("xyz")
      end
    end

    context "JSON value 内 escape された quote" do
      let(:input) { '{"api_key": "ABC\\"DEF"}' }

      it "全 value をマスク(後半残らない)" do
        expect(subject).to eq('{"api_key": "[FILTERED]"}')
      end
    end

    context "JSON value 内 unicode escape sequence" do
      let(:input) { '{"signature": "ABC\\u003dDEF"}' }

      it "unicode escape を含む value も全マスク" do
        expect(subject).to eq('{"signature": "[FILTERED]"}')
      end
    end

    context "Bitget HTTP header JSON 形式" do
      let(:input) { '{"ACCESS-PASSPHRASE": "secret123"}' }

      it "ACCESS-PASSPHRASE の JSON value もマスク" do
        expect(subject).to eq('{"ACCESS-PASSPHRASE": "[FILTERED]"}')
      end
    end

    context "key=value 連結代入(`=` 終端)" do
      let(:input) { "api_key=ABC=DEF other=value" }

      it "次の `=` で終端し後続トークンを呑み込まない" do
        expect(subject).to start_with("api_key=[FILTERED]")
        expect(subject).to include("other=value")
      end
    end

    context "URL query string with `?` boundary" do
      let(:input) { "api_key=ABC?next=value" }

      it "`?` を終端と認識する" do
        expect(subject).to eq("api_key=[FILTERED]?next=value")
      end
    end

    context "URL fragment with `#` boundary" do
      let(:input) { "api_key=ABC#fragment" }

      it "`#` を終端と認識する" do
        expect(subject).to eq("api_key=[FILTERED]#fragment")
      end
    end

    context "URL parameter 形式" do
      let(:input) { "?api_key=ABC123&other=value" }

      it "& を終端と認識して切り分ける" do
        expect(subject).to eq("?api_key=[FILTERED]&other=value")
      end
    end

    context "通常の日本語テキスト「passphrase は秘密です」(= 前置き欠如で誤マスクしない)" do
      let(:input) { "passphrase は秘密です" }

      it { is_expected.to eq("passphrase は秘密です") }
    end

    context "通常の日本語テキスト「設計書の signature について追記する」" do
      let(:input) { "設計書の signature について追記する" }

      it { is_expected.to eq("設計書の signature について追記する") }
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
