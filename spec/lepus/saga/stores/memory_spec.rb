# frozen_string_literal: true

RSpec.describe Lepus::Saga::Stores::Memory do
  let(:store) { described_class.new }

  it_behaves_like "a lepus saga store"
  it_behaves_like "a lepus saga engine"

  it "forgets everything on clear!" do
    execution = store.create_execution(saga_name: "s", resource_type: "R", resource_id: "1", started_at: Time.current)

    store.clear!

    expect(store.find_execution(execution.id)).to be_nil
  end

  it "raises when locking an execution that is gone" do
    execution = store.create_execution(saga_name: "s", resource_type: "R", resource_id: "1", started_at: Time.current)
    store.clear!

    expect { store.with_lock(execution) { nil } }.to raise_error(described_class::RecordNotFound)
  end
end
