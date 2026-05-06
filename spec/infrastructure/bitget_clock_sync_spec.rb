require "rails_helper"

RSpec.describe Infrastructure::BitgetClockSync do
  let(:rest_client) { instance_double(Infrastructure::BitgetRestClient) }
  let(:current_local_time) { Time.utc(2026, 5, 6, 12, 0, 0) }
  let(:clock) { -> { current_local_time } }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }
  let(:sync) do
    described_class.new(rest_client: rest_client, clock: clock, logger: logger)
  end

  describe "#offset(初期状態)" do
    it "0 秒(初回 sync 前)" do
      expect(sync.offset).to eq(0.0)
    end
  end

  describe "#synced_now(初期状態)" do
    it "clock.call をそのまま返す" do
      expect(sync.synced_now).to eq(current_local_time)
    end
  end

  describe "#sync!" do
    let(:server_time_ms) { (current_local_time.to_f * 1000).to_i + 5_000 }

    before do
      allow(rest_client).to receive(:request).with(
        :get, "/api/v2/public/time", auth: false, endpoint_key: :server_time
      ).and_return({ "data" => { "serverTime" => server_time_ms.to_s } })
    end

    it "offset が (server_time - local_time) 秒で更新される" do
      sync.sync!
      # server が 5 秒進んでいる想定
      expect(sync.offset).to be_within(0.01).of(5.0)
    end

    it "synced_now が clock.call + offset を返す" do
      sync.sync!
      expect(sync.synced_now).to be_within(0.01.seconds).of(current_local_time + 5)
    end

    it "logger.info で sync 結果を出力する" do
      sync.sync!
      expect(logger).to have_received(:info).with(/clock sync.*offset/)
    end
  end

  describe "#sync! 失敗時の挙動" do
    before do
      allow(rest_client).to receive(:request).and_raise(StandardError, "network error")
    end

    it "logger.error で記録 + offset は変更されない(防衛的フォールバック)" do
      sync.sync!
      expect(sync.offset).to eq(0.0)
      expect(logger).to have_received(:error).with(/clock sync failed/)
    end
  end
end
