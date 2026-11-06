# frozen_string_literal: true

RSpec.describe Lepus::Saga::Definition do
  let!(:workflow) do
    stub_const("DefinitionWorkflow", Class.new(described_class) do
      saga_name "definition_spec.workflow"

      step :first, compensate: :undo_first, retry: {attempts: 5}
      step :second

      private

      def first = nil

      def second = nil

      def undo_first = nil
    end)
  end

  it "registers the saga name in the registry" do
    expect(Lepus::Saga.find_definition!("definition_spec.workflow")).to eq(workflow)
  end

  it "raises for unknown saga names" do
    expect { Lepus::Saga.find_definition!("nope") }.to raise_error(Lepus::Saga::UnknownSagaError)
  end

  it "declares ordered steps with compensation and retry policy" do
    expect(workflow.steps.map(&:name)).to eq(%w[first second])
    expect(workflow.find_step!(:first).compensate).to eq("undo_first")
    expect(workflow.find_step!(:first).retry_policy.attempts).to eq(5)
    expect(workflow.find_step!(:second).retry_policy.attempts).to eq(3)
    expect(workflow.find_step!(:second)).not_to be_compensatable
  end

  it "requires a saga name and steps to start" do
    expect { Class.new(described_class).start(resource: order) }.to raise_error(ArgumentError, /no saga_name/)
  end

  it "looks the resource up by type and id" do
    execution = workflow.start(resource: order)

    expect(workflow.new(execution).resource).to eq(order)
  end

  it "raises for unknown steps" do
    expect { workflow.find_step!(:missing) }.to raise_error(Lepus::Saga::UnknownStepError)
  end

  it "creates a running execution pointing at the first step" do
    execution = workflow.start(resource: order, context: {"name" => order.name})

    expect(execution).to have_attributes(
      saga_name: "definition_spec.workflow",
      resource_type: "Order",
      resource_id: order.id,
      status: "running",
      current_step: "first",
      direction: "execute",
      context: {"name" => order.name}
    )
    expect(execution.started_at).not_to be_nil
  end

  it "generates a uuid v7 id for the execution" do
    execution = workflow.start(resource: order)

    expect(execution.id).to match(/\A\h{8}-\h{4}-7\h{3}-\h{4}-\h{12}\z/)
  end

  it "publishes the first step message" do
    execution = workflow.start(resource: order)

    messages = saga_exchange.find_messages(routing_key: "saga.execute.default")
    expect(messages.size).to eq(1)
    expect(JSON.parse(messages.first[:payload])).to eq(
      "execution_id" => execution.id,
      "saga" => "definition_spec.workflow",
      "step" => "first",
      "direction" => "execute",
      "epoch" => 0
    )
  end

  it "accepts a hash resource reference" do
    execution = workflow.start(resource: {type: "Order", id: "abc-123"})

    expect(execution.resource_type).to eq("Order")
    expect(execution.resource_id).to eq("abc-123")
  end

  it "routes to the definition partition when none is given" do
    execution = workflow.start(resource: order)

    expect(execution[:partition]).to be_nil
    expect(execution.partition).to eq("default")
  end

  it "inherits its parent's partition" do
    base = Class.new(described_class) { partition "batch" }
    child = Class.new(base)

    expect(child.partition).to eq("batch")
  end

  it "publishes on the given partition" do
    workflow.start(resource: order, partition: "priority")

    expect(saga_exchange.find_messages(routing_key: "saga.execute.priority").size).to eq(1)
    expect(saga_exchange.find_messages(routing_key: "saga.execute.default")).to be_empty
  end

  it "keeps the execution on its partition when retried" do
    execution = workflow.start(resource: order, partition: "priority")
    Lepus::Saga.store.update_execution(execution, status: "failed")
    Lepus::Testing.clear_all_messages!

    Lepus::Saga.retry(execution)

    expect(saga_exchange.find_messages(routing_key: "saga.execute.priority").size).to eq(1)
  end
end
