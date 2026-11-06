# frozen_string_literal: true

require "lepus/testing"
require "lepus/saga/testing"
require_relative "helpers"

# The engine's behaviour (executor, retry, compensate, resume_stuck) run end to
# end on a store, with Lepus fake publishing. The including group defines
# `store` and starts each example with empty storage:
#
#   RSpec.describe MyStore do
#     let(:store) { described_class.new }
#
#     it_behaves_like "a lepus saga engine"
#   end
#
# Pass `concurrency: false` to skip the examples that deliver from threads.
RSpec.shared_examples "a lepus saga engine" do |concurrency: true|
  include Lepus::Saga::ExampleHelpers

  # Step behaviour is driven by the execution context so each example declares
  # its own scenario: "<step>_transient_failures" fails the first N attempts,
  # "fail_<step>" raises a permanent failure, "skip_second" skips, and
  # "complete_on_first" finishes the saga early.
  let(:workflow) do
    stub_const("LepusSagaEngineWorkflow", Class.new(Lepus::Saga::Definition) do
      saga_name "engine_examples.workflow"

      step :first, compensate: :undo_first
      step :second, retry: {attempts: 2}
      step :third

      private

      def first
        complete!("early exit") if context["complete_on_first"]
        fail!("first rejected") if context["fail_first"]
        sleep context["first_sleep"] if context["first_sleep"]
        context["first_output"] = "ok"
      end

      def second
        skip!("not needed") if context["skip_second"]
        fail!("second rejected") if context["fail_second"]
        raise "transient boom" if context.fetch("second_transient_failures", 0) >= step_attempt.attempt

        context["second_output"] = "ok"
      end

      def third = nil

      def undo_first
        raise "undo boom" if context["fail_undo_first"]

        context["undone_first"] = true
      end
    end)
  end

  # Nothing to undo, so abandoning it goes straight to failed rather than
  # through compensation.
  let(:uncompensated) do
    stub_const("LepusSagaEngineUncompensated", Class.new(Lepus::Saga::Definition) do
      saga_name "engine_examples.uncompensated"

      step :only

      private

      def only = nil
    end)
  end

  let(:consumer) do
    stub_const("LepusSagaEngineConsumer", Class.new(Lepus::Saga::ExecutorConsumer) { saga_partition "default" })
  end
  let(:config) { Lepus::Saga.config }
  let(:resource) { {type: "Order", id: "order-1"} }

  around do |example|
    previous = Lepus::Saga.config.store
    Lepus::Saga.config.store = store
    Lepus::Testing.enable!
    Lepus::Testing.clear_all_messages!
    example.run
  ensure
    Lepus::Testing.clear_all_messages!
    Lepus::Saga.config.store = previous
  end

  def saga_exchange = Lepus::Testing.exchange(Lepus::Saga.exchange_name)

  def drain = Lepus::Saga::Testing.drain(consumer: consumer)

  def reload(execution) = store.find_execution(execution.id)

  def force_update(execution, **attributes)
    store.update_execution(reload(execution), attributes)
  end

  def open_attempt(execution, **attributes)
    store.create_step_attempt(execution, {step_name: "first", direction: "execute", epoch: 0, attempt: 1, started_at: Time.now.utc}.merge(attributes))
  end

  def start_and_drain(context = {})
    execution = workflow.start(resource: resource, context: context)
    drain
    reload(execution)
  end

  # The [name, payload[key]] pairs of the saga events instrumented from now on.
  def record_events(key = :step)
    events = []
    allow(Lepus).to receive(:instrument).and_wrap_original do |original, name, **payload, &block|
      events << [name, payload[key]] if name.start_with?("saga.")
      original.call(name, **payload, &block)
    end
    events
  end

  def perform_message(payload)
    Lepus::Testing.consumer_perform(consumer, {payload: payload.to_json})
  end

  def execution_payload(execution, step:, direction: "execute", epoch: nil)
    {
      "execution_id" => execution.id,
      "saga" => execution.saga_name,
      "step" => step,
      "direction" => direction,
      "epoch" => epoch.nil? ? execution.epoch : execution.epoch + epoch
    }
  end

  def attempts(execution, **filters)
    store.step_attempts(execution).select do |attempt|
      filters.all? { |name, value| attempt.public_send(name) == value }
    end
  end

  def succeeded_steps(execution, epoch: 0)
    attempts(execution, status: "succeeded", direction: "execute", epoch: epoch).map(&:step_name)
  end

  def attempt_statuses(execution, step_name)
    attempts(execution, step_name: step_name).map(&:status)
  end

  describe "executor" do
    it "runs all steps to completion and persists context" do
      execution = start_and_drain

      expect(execution.status).to eq("completed")
      expect(execution.finished_at).not_to be_nil
      expect(execution.context).to include("first_output" => "ok", "second_output" => "ok")
      expect(succeeded_steps(execution)).to eq(%w[first second third])
    end

    it "publishes the first step message on start" do
      execution = workflow.start(resource: resource)

      messages = saga_exchange.find_messages(routing_key: "saga.execute.default")
      expect(messages.size).to eq(1)
      expect(JSON.parse(messages.first[:payload])).to eq(
        "execution_id" => execution.id,
        "saga" => "engine_examples.workflow",
        "step" => "first",
        "direction" => "execute",
        "epoch" => 0
      )
    end

    it "finishes the execution early on complete!" do
      execution = start_and_drain("complete_on_first" => true)

      expect(execution.status).to eq("completed")
      expect(execution.context["completed_reason"]).to eq("early exit")
      expect(attempts(execution).map(&:step_name)).to eq(%w[first])
    end

    it "records the step as skipped on skip! and continues" do
      execution = start_and_drain("skip_second" => true)

      expect(execution.status).to eq("completed")
      expect(attempt_statuses(execution, "second").last).to eq("skipped")
      expect(succeeded_steps(execution)).to include("third")
    end

    it "retries transient failures until the step succeeds" do
      execution = start_and_drain("second_transient_failures" => 1)

      expect(execution.status).to eq("completed")
      expect(attempt_statuses(execution, "second")).to eq(%w[failed succeeded])
    end

    it "compensates succeeded steps when retries are exhausted" do
      execution = start_and_drain("second_transient_failures" => 99)

      expect(execution.status).to eq("compensated")
      expect(execution.failure_reason).to eq("transient boom")
      expect(attempt_statuses(execution, "second")).to eq(%w[failed failed])
      expect(sole(attempts(execution, step_name: "first", direction: "compensate")).status).to eq("succeeded")
      expect(execution.context["undone_first"]).to be(true)
    end

    it "compensates immediately without retrying on fail!" do
      execution = start_and_drain("fail_second" => true)

      expect(execution.status).to eq("compensated")
      expect(execution.failure_reason).to eq("second rejected")
      expect(attempt_statuses(execution, "second")).to eq(%w[failed])
    end

    it "fails without compensation when nothing succeeded before the failure" do
      execution = start_and_drain("fail_first" => true)

      expect(execution.status).to eq("failed")
      expect(execution.failure_reason).to eq("first rejected")
      expect(attempts(execution, direction: "compensate")).to be_empty
    end

    it "stores a failure reason longer than 255 characters" do
      execution = workflow.start(resource: resource)

      Lepus::Saga.compensate(execution, reason: "x" * 1000)

      expect(reload(execution)).to have_attributes(status: "failed", failure_reason: "x" * 1000)
    end

    it "marks the execution compensation_failed when a compensation exhausts retries" do
      execution = start_and_drain("fail_second" => true, "fail_undo_first" => true)

      expect(execution).to have_attributes(status: "compensation_failed", current_step: "first", direction: "compensate")
    end

    it "acks stale-epoch messages without running anything" do
      execution = start_and_drain

      expect { expect(perform_message(execution_payload(execution, step: "first", epoch: -1))).to eq(:ack) }
        .not_to change { attempts(execution).size }
    end

    it "acks terminal executions without running anything" do
      execution = start_and_drain

      expect { expect(perform_message(execution_payload(execution, step: execution.current_step))).to eq(:ack) }
        .not_to change { attempts(execution).size }
    end

    it "heals a cursor mismatch by re-publishing the current step" do
      execution = workflow.start(resource: resource)
      Lepus::Testing.clear_all_messages!
      force_update(execution, current_step: "second")

      result = perform_message(execution_payload(execution, step: "first"))

      expect(result).to eq(:ack)
      expect(attempts(execution)).to be_empty
      expect(JSON.parse(sole(saga_exchange.messages)[:payload])["step"]).to eq("second")
    end

    it "acks while another attempt is in flight" do
      execution = workflow.start(resource: resource)
      open_attempt(execution)

      result = perform_message(execution_payload(execution, step: "first"))

      expect(result).to eq(:ack)
      expect(attempts(execution).size).to eq(1)
    end

    it "closes abandoned attempts and runs a fresh one" do
      execution = workflow.start(resource: resource)
      stale = open_attempt(execution, started_at: ago(minutes(10)))

      perform_message(execution_payload(execution, step: "first"))

      expect(sole(attempts(execution, id: stale.id))).to have_attributes(
        status: "failed", error_class: Lepus::Saga::Executor::AbandonedAttempt.name
      )
      expect(sole(attempts(execution, attempt: 2)).status).to eq("succeeded")
    end

    it "honours config.stale_running_attempt_after" do
      allow(config).to receive(:stale_running_attempt_after).and_return(minutes(1))
      execution = workflow.start(resource: resource)
      stale = open_attempt(execution, started_at: ago(minutes(2)))

      perform_message(execution_payload(execution, step: "first"))

      expect(sole(attempts(execution, id: stale.id)).status).to eq("failed")
    end

    it "acks a duplicate attempt and keeps the store unchanged" do
      execution = workflow.start(resource: resource)
      allow(store).to receive(:count_step_attempts).and_return(0)
      open_attempt(execution, started_at: ago(minutes(10)))

      expect(perform_message(execution_payload(execution, step: "first"))).to eq(:ack)
      expect(sole(attempts(execution)).status).to eq("running")
    end

    it "acks messages for unknown executions" do
      result = perform_message(
        "execution_id" => SecureRandom.uuid_v7, "saga" => "engine_examples.workflow",
        "step" => "first", "direction" => "execute", "epoch" => 0
      )

      expect(result).to eq(:ack)
    end

    it "emits instrumentation events through the lifecycle" do
      events = record_events

      start_and_drain

      expect(events).to include(
        ["saga.started", nil],
        ["saga.step.started", "first"],
        ["saga.step.finished", "third"],
        ["saga.completed", nil]
      )
    end

    if concurrency
      it "runs a step once when its message is delivered twice at the same time" do
        execution = workflow.start(resource: resource, context: {"first_sleep" => 0.3})
        payload = execution_payload(execution, step: "first")

        Array.new(2) { Thread.new { perform_message(payload) } }.each(&:join)

        expect(attempts(execution, step_name: "first").map(&:status)).to eq(%w[succeeded])
        expect(reload(execution).current_step).to eq("second")
      end
    end
  end

  describe "Lepus::Saga.retry" do
    it "resumes a failed execution under a new epoch" do
      execution = start_and_drain("fail_first" => true)
      force_update(execution, context: {})

      Lepus::Saga.retry(reload(execution))
      drain
      execution = reload(execution)

      expect(execution.status).to eq("completed")
      expect(execution.epoch).to eq(1)
      expect(succeeded_steps(execution, epoch: 1)).to eq(%w[first second third])
    end

    it "refreshes and returns the given record" do
      execution = start_and_drain("fail_first" => true)

      expect(Lepus::Saga.retry(execution)).to equal(execution)
      expect(execution).to have_attributes(status: "running", epoch: 1, failure_reason: nil, finished_at: nil)
    end

    it "refuses to retry completed executions" do
      execution = start_and_drain

      expect { Lepus::Saga.retry(execution) }.to raise_error(Lepus::Saga::NotRetryableError)
    end

    it "refuses a stale copy of an execution that completed since it was loaded" do
      stale = workflow.start(resource: resource)
      drain
      Lepus::Testing.clear_all_messages!

      expect { Lepus::Saga.retry(stale) }.to raise_error(Lepus::Saga::NotRetryableError)
      expect(reload(stale)).to have_attributes(status: "completed", epoch: 0)
      expect(saga_exchange.messages).to be_empty
    end

    it "keeps the execution on its partition" do
      execution = workflow.start(resource: resource, partition: "priority")
      force_update(execution, status: "failed")
      Lepus::Testing.clear_all_messages!

      Lepus::Saga.retry(reload(execution))

      expect(saga_exchange.find_messages(routing_key: "saga.execute.priority").size).to eq(1)
    end
  end

  describe "Lepus::Saga.compensate" do
    it "refuses a stale copy of an execution that completed since it was loaded" do
      stale = workflow.start(resource: resource)
      drain
      Lepus::Testing.clear_all_messages!

      expect { Lepus::Saga.compensate(stale) }.to raise_error(Lepus::Saga::NotRetryableError)
      expect(reload(stale)).to have_attributes(status: "completed", epoch: 0)
      expect(saga_exchange.messages).to be_empty
    end

    it "aborts a running execution" do
      execution = start_and_drain
      force_update(execution, status: "running", finished_at: nil, current_step: "third")

      Lepus::Saga.compensate(reload(execution))
      drain

      expect(reload(execution).status).to eq("compensated")
      expect(reload(execution).context["undone_first"]).to be(true)
    end

    it "fences out in-flight messages by bumping the epoch" do
      execution = workflow.start(resource: resource)
      payload = execution_payload(execution, step: "first")

      Lepus::Saga.compensate(execution)

      expect(execution).to have_attributes(status: "failed", epoch: 1, failure_reason: "manually compensated")
      expect(perform_message(payload)).to eq(:ack)
      expect(attempts(execution)).to be_empty
    end
  end

  describe "Lepus::Saga.resume_stuck" do
    # An execution left with its cursor standing still for an hour. `advance`
    # runs the first step first, so there is a succeeded attempt to compensate.
    def stalled_execution(resume_count: 0, advance: false)
      execution = workflow.start(resource: resource)
      perform_next_step if advance
      Lepus::Testing.clear_all_messages!
      force_update(execution, last_progress_at: ago(hours(1)), resume_count: resume_count)
    end

    # One message only: Saga::Testing.drain runs to completion and raises if
    # the exchange never empties, which is the opposite of what these need.
    def perform_next_step
      message = saga_exchange.messages.first
      saga_exchange.clear_messages
      Lepus::Testing.consumer_perform(consumer, {payload: message[:payload]})
    end

    # Queues bare step messages without creating executions, so the only
    # stalled executions are the ones an example sets up.
    def fill_queue(messages: config.backlog_threshold + 1, partition: "default")
      routing_key = Lepus::Saga.routing_key(partition)
      messages.times { saga_exchange.add_message(payload: {}, routing_key: routing_key) }
    end

    it "re-publishes the current step of a stalled execution" do
      execution = stalled_execution

      expect(Lepus::Saga.resume_stuck(older_than: minutes(15))).to eq(1)
      drain

      expect(reload(execution).status).to eq("completed")
    end

    it "re-publishes an execution whose cursor has not moved" do
      execution = stalled_execution

      expect(Lepus::Saga.resume_stuck).to eq(1)
      expect(reload(execution).resume_count).to eq(1)
      expect(saga_exchange.messages.size).to eq(1)
    end

    # The bug this exists for: a wedged execution is written to on every pass
    # (a lock, a re-publish, an attempt opened and abandoned), so selecting on
    # `updated_at` let it reset its own clock and it was never picked up again.
    it "re-publishes an execution that is still being written to" do
      execution = stalled_execution
      force_update(execution, updated_at: Time.now.utc)

      expect(Lepus::Saga.resume_stuck).to eq(1)
      expect(reload(execution).resume_count).to eq(1)
    end

    it "reports the stored resume count" do
      stalled_execution(resume_count: 2)
      events = record_events(:resume_count)

      Lepus::Saga.resume_stuck

      expect(events).to eq([["saga.resumed", 3]])
    end

    it "leaves an execution whose cursor moved recently alone" do
      execution = stalled_execution
      force_update(execution, last_progress_at: ago(minutes(1)))

      expect(Lepus::Saga.resume_stuck).to eq(0)
      expect(reload(execution).resume_count).to eq(0)
      expect(saga_exchange.messages).to be_empty
    end

    it "resets the resume budget when a step advances" do
      execution = stalled_execution(resume_count: 3)

      Lepus::Saga.resume_stuck
      drain

      expect(reload(execution)).to have_attributes(status: "completed", resume_count: 0)
    end

    it "compensates an execution that never recovers" do
      execution = stalled_execution(resume_count: config.max_resumes, advance: true)

      expect(Lepus::Saga.resume_stuck).to eq(0)
      expect(reload(execution)).to have_attributes(status: "compensating", failure_reason: "no progress after 5 resume attempts")
    end

    it "does not abandon an execution that completed after it was listed" do
      execution = stalled_execution(resume_count: config.max_resumes, advance: true)
      listed = reload(execution)
      force_update(execution, status: "completed", finished_at: Time.now.utc)
      allow(store).to receive(:stalled_executions).and_return([listed])

      Lepus::Saga.resume_stuck

      expect(reload(execution)).to have_attributes(status: "completed", failure_reason: nil)
      expect(saga_exchange.messages).to be_empty
    end

    it "honours config.max_resumes" do
      allow(config).to receive(:max_resumes).and_return(2)
      execution = stalled_execution(resume_count: 2, advance: true)

      Lepus::Saga.resume_stuck

      expect(reload(execution).failure_reason).to eq("no progress after 2 resume attempts")
    end

    it "fails an execution that never recovers and has nothing to compensate" do
      execution = uncompensated.start(resource: resource)
      Lepus::Testing.clear_all_messages!
      force_update(execution, last_progress_at: ago(hours(1)), resume_count: config.max_resumes)

      expect(Lepus::Saga.resume_stuck).to eq(0)
      expect(reload(execution).status).to eq("failed")
      expect(reload(execution).finished_at).not_to be_nil
    end

    it "gives an abandoned execution a fresh budget on manual retry" do
      execution = stalled_execution(resume_count: config.max_resumes, advance: true)
      Lepus::Saga.resume_stuck
      Lepus::Testing.clear_all_messages!

      Lepus::Saga.retry(reload(execution))

      expect(reload(execution).resume_count).to eq(0)
      expect(Lepus::Saga.resume_stuck).to eq(0)
    end

    it "honours the limit so one sweep cannot run away" do
      3.times { stalled_execution }

      expect(Lepus::Saga.resume_stuck(limit: 2)).to eq(2)
    end

    it "resumes the oldest stall first" do
      newer = stalled_execution
      older = stalled_execution
      force_update(older, last_progress_at: ago(hours(2)))

      Lepus::Saga.resume_stuck(limit: 1)

      expect([reload(older).resume_count, reload(newer).resume_count]).to eq([1, 0])
    end

    # Under a backlog an execution's step message is still queued, so its
    # cursor stands still while it waits its turn; re-publishing it only adds
    # duplicates.
    it "leaves executions alone while their partition's queue has a backlog" do
      execution = stalled_execution
      fill_queue

      expect(Lepus::Saga.resume_stuck).to eq(0)
      expect(reload(execution).resume_count).to eq(0)
    end

    it "does not abandon an execution while its partition's queue has a backlog" do
      execution = stalled_execution(resume_count: config.max_resumes)
      fill_queue

      Lepus::Saga.resume_stuck

      expect(reload(execution).status).to eq("running")
    end

    it "does not count a few queued messages as a backlog" do
      execution = stalled_execution
      fill_queue(messages: 2)

      expect(Lepus::Saga.resume_stuck).to eq(1)
      expect(reload(execution).resume_count).to eq(1)
    end

    it "honours config.backlog_threshold" do
      allow(config).to receive(:backlog_threshold).and_return(1)
      stalled_execution
      fill_queue(messages: 2)

      expect(Lepus::Saga.resume_stuck).to eq(0)
    end

    it "re-publishes an execution stalled behind a backlog past the patience window" do
      execution = stalled_execution
      force_update(execution, last_progress_at: ago(config.backlog_patience + hours(1)))
      fill_queue

      expect(Lepus::Saga.resume_stuck).to eq(1)
    end

    it "honours config.backlog_patience" do
      allow(config).to receive(:backlog_patience).and_return(minutes(30))
      stalled_execution
      fill_queue

      expect(Lepus::Saga.resume_stuck).to eq(1)
    end

    it "re-publishes a backlogged execution only once" do
      execution = stalled_execution
      force_update(execution, last_progress_at: ago(config.backlog_patience + hours(1)))
      fill_queue
      Lepus::Saga.resume_stuck

      expect(Lepus::Saga.resume_stuck).to eq(0)
      expect(reload(execution).resume_count).to eq(1)
    end

    it "does not let a backlog in another partition hold this one back" do
      execution = stalled_execution
      fill_queue(partition: "organic")

      expect(Lepus::Saga.resume_stuck).to eq(1)
      expect(reload(execution).resume_count).to eq(1)
    end
  end
end
