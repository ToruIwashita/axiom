require "rails_helper"

RSpec.describe Domain::TradingScriptBase do
  let(:script_class) do
    Class.new(described_class) do
      def on_start(ctx)
        :start_called
      end

      def on_tick(ctx, candle)
        [ :tick_called, candle ]
      end

      def on_order_event(ctx, event)
        [ :order_event_called, event ]
      end

      def on_stop(ctx)
        :stop_called
      end
    end
  end
  let(:script) { script_class.new(:params) }
  let(:ctx) { instance_double("Object") }

  describe "#initialize" do
    subject { described_class.new(:any_params) }

    context "params を受け取った場合" do
      it "例外なくインスタンス化される" do
        expect { subject }.not_to raise_error
      end
    end

    context "引数なしで呼び出した場合" do
      subject { described_class.new }

      it "例外なくインスタンス化される" do
        expect { subject }.not_to raise_error
      end
    end
  end

  describe "#on_start" do
    context "サブクラスで override した場合" do
      subject { script.on_start(ctx) }

      it "override の戻り値を返す" do
        expect(subject).to eq(:start_called)
      end
    end

    context "基底クラスのデフォルト実装の場合" do
      subject { described_class.new.on_start(ctx) }

      it "nil を返す(no-op)" do
        expect(subject).to be_nil
      end
    end
  end

  describe "#on_tick" do
    context "サブクラスで override した場合" do
      subject { script.on_tick(ctx, :candle_value) }

      it "override の戻り値を返す" do
        expect(subject).to eq([ :tick_called, :candle_value ])
      end
    end

    context "基底クラスのデフォルト実装の場合" do
      subject { described_class.new.on_tick(ctx, :candle_value) }

      it "nil を返す(no-op)" do
        expect(subject).to be_nil
      end
    end
  end

  describe "#on_order_event" do
    context "サブクラスで override した場合" do
      subject { script.on_order_event(ctx, :event_value) }

      it "override の戻り値を返す" do
        expect(subject).to eq([ :order_event_called, :event_value ])
      end
    end

    context "基底クラスのデフォルト実装の場合" do
      subject { described_class.new.on_order_event(ctx, :event_value) }

      it "nil を返す(no-op)" do
        expect(subject).to be_nil
      end
    end
  end

  describe "#on_stop" do
    context "サブクラスで override した場合" do
      subject { script.on_stop(ctx) }

      it "override の戻り値を返す" do
        expect(subject).to eq(:stop_called)
      end
    end

    context "基底クラスのデフォルト実装の場合" do
      subject { described_class.new.on_stop(ctx) }

      it "nil を返す(no-op)" do
        expect(subject).to be_nil
      end
    end
  end
end
