# frozen_string_literal: true

RSpec.describe Lepus::Saga::QueueDepth do
  let(:execution) do
    Lepus::Saga.store.create_execution(
      saga_name: "orders.checkout", resource_type: "Order", resource_id: order.id,
      current_step: "persist_local", started_at: Time.current
    )
  end

  def publish_step(partition)
    execution.partition = partition
    Lepus::Saga::StepProducer.publish_step(execution)
  end

  it "counts the step messages waiting for a partition" do
    2.times { publish_step("organic") }
    publish_step("default")

    expect(described_class.call("organic")).to eq(2)
  end

  it "is zero for a partition with nothing queued" do
    publish_step("organic")

    expect(described_class.call("default")).to eq(0)
  end
end
