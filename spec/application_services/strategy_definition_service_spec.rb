require "rails_helper"

RSpec.describe ApplicationServices::StrategyDefinitionService do
  let(:service) { described_class.new }

  describe "#create" do
    subject { service.create(name: "New Strat", description: "desc", market_type: "futures") }

    context "全 keyword 引数を渡した場合" do
      it "Strategy::Definition を新規作成し active 状態で返す" do
        expect { subject }.to change { Strategy::Definition.count }.by(1)
        expect(subject).to be_a(Strategy::Definition)
        expect(subject.name).to eq("New Strat")
        expect(subject.description).to eq("desc")
        expect(subject.market_type).to eq("futures")
        expect(subject).to be_state_active
      end
    end

    context "description を省略した場合" do
      subject { service.create(name: "No Desc", market_type: "spot") }

      it "description が nil で作成される" do
        expect(subject.description).to be_nil
      end
    end

    context "name が空の場合" do
      subject { service.create(name: "", market_type: "futures") }

      it "ActiveRecord::RecordInvalid を raise する" do
        expect { subject }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  describe "#update" do
    let!(:definition) { Strategy::Definition.create!(name: "Old", market_type: "futures", status: "active") }

    context "name と description を渡した場合" do
      subject { service.update(definition_id: definition.id, name: "New", description: "updated") }

      it "属性が更新される" do
        result = subject
        expect(result.reload.name).to eq("New")
        expect(result.description).to eq("updated")
      end
    end

    context "name のみ渡した場合" do
      subject { service.update(definition_id: definition.id, name: "OnlyName") }

      it "name のみ更新され description は変化しない" do
        result = subject
        expect(result.reload.name).to eq("OnlyName")
        expect(result.description).to be_nil
      end
    end

    context "存在しない definition_id を渡した場合" do
      subject { service.update(definition_id: 0, name: "X") }

      it "ActiveRecord::RecordNotFound を raise する" do
        expect { subject }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "#archive" do
    let!(:definition) { Strategy::Definition.create!(name: "ToArchive", market_type: "futures", status: "active") }

    subject { service.archive(definition_id: definition.id) }

    context "active 状態の Definition を archive する場合" do
      it "status が archived に遷移する" do
        result = subject
        expect(result.reload).to be_state_archived
      end
    end
  end

  describe "#get" do
    let!(:definition) { Strategy::Definition.create!(name: "G", market_type: "futures", status: "active") }

    context "存在する definition_id を渡した場合" do
      subject { service.get(definition_id: definition.id) }

      it "Strategy::Definition を返す" do
        expect(subject).to eq(definition)
      end
    end

    context "存在しない definition_id を渡した場合" do
      subject { service.get(definition_id: 0) }

      it "ActiveRecord::RecordNotFound を raise する" do
        expect { subject }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "#list" do
    subject { service.list.to_a }

    context "複数の Definition が存在する場合" do
      let!(:older) { Strategy::Definition.create!(name: "Older", market_type: "futures", status: "active", created_at: 2.days.ago) }
      let!(:newer) { Strategy::Definition.create!(name: "Newer", market_type: "futures", status: "active", created_at: 1.day.ago) }

      it "created_at desc 順で返される" do
        expect(subject.first(2)).to eq([ newer, older ])
      end
    end
  end
end
