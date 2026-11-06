# frozen_string_literal: true

module Lepus
  module Saga
    # Runs one unit of saga work for a step message. The store is the source
    # of truth: messages only point at the execution, so duplicate or stale
    # deliveries are fenced out and lost publishes are healed by re-publishing
    # whatever the execution record says is current.
    #
    # Returns :ack (message done) or :retry (transient failure — the consumer
    # rejects the message into the TTL retry queue).
    class Executor
      class AbandonedAttempt < StandardError
        def initialize = super("attempt abandoned (worker died or lost the message)")
      end

      class << self
        # Switches an execution onto the compensation path (or straight to
        # failed when there is nothing to undo). Caller must hold the row lock
        # and is responsible for instrumentation and publishing afterwards.
        def begin_compensation(execution, reason:)
          target = compensation_target(execution)

          if target
            # Switching onto the compensation path is a cursor move, so the
            # compensation gets its own stall window and resume budget.
            execution.record_progress
            store.update_execution(execution,
              status: "compensating", direction: "compensate",
              current_step: target.name, failure_reason: reason)
          else
            store.update_execution(execution,
              status: "failed", failure_reason: reason, **execution.finish_attributes)
          end
          execution
        end

        # The nearest step before the current one that succeeded and declares
        # a compensation. Skipped or never-run steps have nothing to undo.
        def compensation_target(execution)
          index = execution.definition_class.step_index(execution.current_step) ||
            execution.steps.size
          execution.steps.first(index).reverse.find do |step|
            step.compensatable? && store.step_succeeded?(execution, step.name)
          end
        end

        private

        def store = Lepus::Saga.store
      end

      def initialize(payload)
        @payload = payload.to_h.transform_keys(&:to_s)
      end

      def run
        case prepare
        when :proceed then run_step
        when :exhausted then announce_failure
        else :ack
        end
      end

      private

      attr_reader :payload, :execution, :attempt, :failure_outcome

      def message_epoch = payload.fetch("epoch", 0).to_i

      def message_step = payload["step"]

      def message_direction = payload.fetch("direction", "execute")

      def stale_running_attempt_after = Lepus::Saga.config.stale_running_attempt_after

      def store = Lepus::Saga.store

      # Fences the message against the execution record and opens a step
      # attempt, all while holding the execution's lock.
      def prepare
        store.with_locked_execution(payload["execution_id"]) do |locked|
          @execution = locked
          next :ack unless execution
          next :ack if execution.terminal?
          next :ack if message_epoch < execution.epoch

          unless message_step == execution.current_step && message_direction == execution.direction
            StepProducer.publish_step(execution)
            next :ack
          end

          next :ack if attempt_in_flight?

          if attempts_so_far >= retry_policy.attempts
            @failure_outcome = apply_failure(execution.failure_reason || "retries exhausted")
            next :exhausted
          end

          open_attempt
          :proceed
        end
      rescue DuplicateAttemptError
        :ack
      end

      def attempts_so_far
        @attempts_so_far ||= begin
          close_abandoned_attempts
          store.count_step_attempts(execution, **execution.current_step_scope)
        end
      end

      def attempt_in_flight?
        store.running_step_attempt?(execution, **execution.current_step_scope,
          started_since: Time.now.utc - stale_running_attempt_after)
      end

      def close_abandoned_attempts
        store.stale_step_attempts(execution, **execution.current_step_scope,
          started_before: Time.now.utc - stale_running_attempt_after)
          .each { |stale| store.finish_step_attempt(stale, "failed", error: AbandonedAttempt.new) }
      end

      def open_attempt
        @attempt = store.create_step_attempt(execution,
          step_name: execution.current_step,
          direction: execution.direction,
          epoch: execution.epoch,
          attempt: attempts_so_far + 1,
          started_at: Time.now.utc)
        Instrumentation.saga_event("saga.step.started", execution,
          step: attempt.step_name, attempt: attempt.attempt)
      end

      # Runs the step (or compensation) method lock-free — slow HTTP calls in
      # user code must not hold the execution row.
      def run_step
        definition = execution.definition_class.new(execution, step_attempt: attempt)
        step = execution.current_step_definition
        definition.send(execution.compensate_direction? ? step.compensate : step.name)
        finish_step("succeeded")
      rescue Control::Skip => signal
        finish_step("skipped", reason: signal.reason)
      rescue Control::Complete => signal
        finish_execution(signal.reason)
      rescue Control::Fail => signal
        store.finish_step_attempt(attempt, "failed", error: signal)
        fail_permanently(signal.reason)
      rescue => error
        store.finish_step_attempt(attempt, "failed", error: error)
        handle_step_error(error)
      end

      def finish_step(attempt_status, reason: nil)
        new_context = execution.context
        completed_event = nil
        finished = with_fresh_lock do
          store.finish_step_attempt(attempt, attempt_status, context_after: new_context)
          execution.context = new_context
          completed_event = advance_cursor
          execution.record_progress
          store.save_execution(execution)
        end
        return :ack unless finished

        step_event = (attempt_status == "skipped") ? "saga.step.skipped" : "saga.step.finished"
        Instrumentation.saga_event(step_event, execution,
          step: attempt.step_name, attempt: attempt.attempt,
          duration_ms: attempt.duration_ms, reason: reason)
        if completed_event
          Instrumentation.saga_event(completed_event, execution)
        else
          StepProducer.publish_step(execution)
        end
        :ack
      end

      def finish_execution(reason)
        new_context = execution.context
        new_context["completed_reason"] = reason if reason
        finished = with_fresh_lock do
          now = Time.now.utc
          store.finish_step_attempt(attempt, "succeeded", context_after: new_context)
          store.update_execution(execution, context: new_context, status: "completed", **execution.finish_attributes(now),
            last_progress_at: now, resume_count: 0)
        end
        return :ack unless finished

        Instrumentation.saga_event("saga.step.finished", execution,
          step: attempt.step_name, attempt: attempt.attempt,
          duration_ms: attempt.duration_ms)
        Instrumentation.saga_event("saga.completed", execution, reason: reason)
        :ack
      end

      # Re-acquires the lock on a fresh copy of the execution after user code
      # ran lock-free. Yields with the lock held; returns false when a manual
      # retry/compensate bumped the epoch in the meantime (this delivery's
      # outcome must not move the cursor).
      def with_fresh_lock
        store.with_locked_execution(execution.id) do |fresh|
          next false if fresh.nil? || fresh.epoch != message_epoch || fresh.terminal?

          @execution = fresh
          yield
          true
        end
      end

      def handle_step_error(error)
        if attempt.attempt < retry_policy.attempts
          Instrumentation.saga_event("saga.step.failed", execution,
            step: attempt.step_name, attempt: attempt.attempt, error: error)
          return :retry
        end

        Instrumentation.saga_event("saga.step.failed", execution,
          step: attempt.step_name, attempt: attempt.attempt,
          error: error, retries_exhausted: true)
        fail_permanently(error.message)
      end

      def fail_permanently(reason)
        with_fresh_lock do
          @failure_outcome = apply_failure(reason)
        end
        announce_failure
      end

      def apply_failure(reason)
        if execution.compensate_direction?
          store.update_execution(execution, status: "compensation_failed", failure_reason: reason,
            **execution.finish_attributes)
          :compensation_failed
        else
          self.class.begin_compensation(execution, reason: reason)
          execution.compensating? ? :compensating : :failed
        end
      end

      def announce_failure
        case failure_outcome
        when :compensation_failed
          Instrumentation.saga_event("saga.compensation_failed", execution)
        when :compensating
          Instrumentation.saga_event("saga.compensation_started", execution)
          StepProducer.publish_step(execution)
        when :failed
          Instrumentation.saga_event("saga.failed", execution)
        end
        :ack
      end

      def advance_cursor
        if execution.compensate_direction?
          target = self.class.compensation_target(execution)
          return complete_as("compensated") unless target

          execution.current_step = target.name
        else
          index = execution.definition_class.step_index(execution.current_step)
          next_step = execution.steps[index + 1]
          return complete_as("completed") unless next_step

          execution.current_step = next_step.name
        end
        nil
      end

      def complete_as(status)
        execution.status = status
        execution.finish_attributes.each { |name, value| execution.public_send(:"#{name}=", value) }
        "saga.#{status}"
      end

      def retry_policy
        execution.current_step_definition.retry_policy
      end
    end
  end
end
