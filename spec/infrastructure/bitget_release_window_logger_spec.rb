require "rails_helper"

RSpec.describe Infrastructure::BitgetReleaseWindowLogger do
  describe ".release_window?" do
    # Bitget の主要リリース時間帯: UTC+8 の火/水/木 14-17 時 = UTC 06-09 時
    context "UTC 火曜 06:00(リリース時間帯開始)" do
      it "true を返す" do
        time = Time.utc(2026, 5, 5, 6, 0, 0) # 2026-05-05 は火曜
        expect(described_class.release_window?(time)).to be true
      end
    end

    context "UTC 水曜 07:30(リリース時間帯内)" do
      it "true を返す" do
        time = Time.utc(2026, 5, 6, 7, 30, 0) # 2026-05-06 は水曜
        expect(described_class.release_window?(time)).to be true
      end
    end

    context "UTC 木曜 08:59:59(リリース時間帯ギリギリ)" do
      it "true を返す" do
        time = Time.utc(2026, 5, 7, 8, 59, 59) # 2026-05-07 は木曜
        expect(described_class.release_window?(time)).to be true
      end
    end

    context "UTC 木曜 09:00(window 終了境界)" do
      it "false を返す(09:00 は範囲外)" do
        time = Time.utc(2026, 5, 7, 9, 0, 0)
        expect(described_class.release_window?(time)).to be false
      end
    end

    context "UTC 月曜(対象曜日外)" do
      it "false を返す" do
        time = Time.utc(2026, 5, 4, 7, 0, 0) # 月曜
        expect(described_class.release_window?(time)).to be false
      end
    end

    context "UTC 金曜(対象曜日外)" do
      it "false を返す" do
        time = Time.utc(2026, 5, 8, 7, 0, 0) # 金曜
        expect(described_class.release_window?(time)).to be false
      end
    end

    context "UTC 火曜 05:59:59(時間帯前)" do
      it "false を返す" do
        time = Time.utc(2026, 5, 5, 5, 59, 59)
        expect(described_class.release_window?(time)).to be false
      end
    end
  end

  describe ".tag_if_release_window" do
    let(:message) { "GET /api/v2/mix/order/place-order" }

    context "リリース時間帯の場合" do
      let(:time) { Time.utc(2026, 5, 5, 7, 0, 0) }

      it "[bitget_release_window] タグを付加して返す" do
        result = described_class.tag_if_release_window(message: message, time: time)
        expect(result).to eq("[bitget_release_window] #{message}")
      end
    end

    context "リリース時間帯外の場合" do
      let(:time) { Time.utc(2026, 5, 5, 12, 0, 0) }

      it "メッセージをそのまま返す" do
        result = described_class.tag_if_release_window(message: message, time: time)
        expect(result).to eq(message)
      end
    end
  end
end
