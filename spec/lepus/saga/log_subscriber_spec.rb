# frozen_string_literal: true

RSpec.describe Lepus::Saga::LogSubscriber do
  let(:output) { StringIO.new }
  let(:execution) do
    Lepus::Saga.store.create_execution(
      saga_name: "orders.checkout", resource_type: "Order", resource_id: order.id,
      status: "completed", current_step: "persist_local", started_at: ago(minutes(1)), finished_at: Time.now.utc
    )
  end

  before do
    allow(Lepus).to receive(:instrument) { |name, **payload| described_class.call(name, payload) }
  end

  around do |example|
    previous_logger = Lepus.logger
    Lepus.logger = Logger.new(output, level: :info)
    example.run
  ensure
    Lepus.logger = previous_logger
  end

  it "logs a completed saga with its resource" do
    Lepus::Saga::Instrumentation.saga_event("saga.completed", execution)

    expect(output.string).to include("INFO")
    expect(output.string).to include(
      "saga.completed execution=#{execution.id} resource=Order/#{execution.resource_id} " \
      "saga_name=orders.checkout status=completed"
    )
  end

  it "logs a finished step with its duration at debug level" do
    Lepus.logger.level = :debug

    Lepus::Saga::Instrumentation.saga_event("saga.step.finished", execution,
      step: "persist_local", attempt: 1, duration_ms: 12.5)

    expect(output.string).to include("DEBUG")
    expect(output.string).to include("step=persist_local attempt=1 duration_ms=12.5")
  end

  it "logs a failed step as a warning with its error" do
    Lepus::Saga::Instrumentation.saga_event("saga.step.failed", execution,
      step: "persist_local", attempt: 2, error: RuntimeError.new("boom"))

    expect(output.string).to include("WARN")
    expect(output.string).to include("error=RuntimeError: boom")
  end

  it "logs a failed saga as an error" do
    Lepus::Saga::Instrumentation.saga_event("saga.failed", execution)

    expect(output.string).to include("ERROR")
    expect(output.string).to include("saga.failed execution=#{execution.id}")
  end

  it "keeps step progress out of info logs" do
    %w[saga.step.started saga.step.finished saga.step.skipped].each do |event|
      Lepus::Saga::Instrumentation.saga_event(event, execution, step: "persist_local", attempt: 1)
    end

    expect(output.string).to be_empty
  end

  context "when subscribed through ActiveSupport::Notifications", :active_support do
    let!(:subscription) do
      ActiveSupport::Notifications.subscribe(/\Asaga\./) do |name, _started, _finished, _id, payload|
        described_class.call(name.delete_suffix(".lepus"), payload)
      end
    end

    after { ActiveSupport::Notifications.unsubscribe(subscription) }

    it "logs the events Lepus.instrument publishes" do
      allow(Lepus).to receive(:instrument).and_call_original

      Lepus::Saga::Instrumentation.saga_event("saga.completed", execution)

      expect(output.string).to include("saga.completed execution=#{execution.id}")
    end
  end
end
