# frozen_string_literal: true

require "securerandom"
require "lepus"
require_relative "saga/version"

module Lepus
  # Temporal-inspired saga orchestration on top of Lepus/RabbitMQ.
  #
  # Sagas are declared as subclasses of Lepus::Saga::Definition (ordered steps
  # with optional compensations and retry policies). State lives in the
  # database (saga_executions + saga_step_attempts); messages on the saga
  # exchange only point at the next unit of work, so redelivery and message
  # loss are both recoverable from the database.
  module Saga
    class UnknownSagaError < StandardError; end
    class UnknownStepError < StandardError; end
    class NotRetryableError < StandardError; end
    class ConfigurationError < StandardError; end
    class DuplicateAttemptError < StandardError; end

    autoload :Configuration, "lepus/saga/configuration"
    autoload :Control, "lepus/saga/control"
    autoload :Definition, "lepus/saga/definition"
    autoload :ExecutionBehaviour, "lepus/saga/execution_behaviour"
    autoload :Executor, "lepus/saga/executor"
    autoload :ExecutorConsumer, "lepus/saga/executor_consumer"
    autoload :Instrumentation, "lepus/saga/instrumentation"
    autoload :LogSubscriber, "lepus/saga/log_subscriber"
    autoload :QueueDepth, "lepus/saga/queue_depth"
    autoload :ResumeStuckJob, "lepus/saga/resume_stuck_job"
    autoload :RetryPolicy, "lepus/saga/retry_policy"
    autoload :Step, "lepus/saga/step"
    autoload :Stores, "lepus/saga/stores"
    autoload :StepAttemptBehaviour, "lepus/saga/step_attempt_behaviour"
    autoload :StepProducer, "lepus/saga/step_producer"
    autoload :Testing, "lepus/saga/testing"

    class << self
      def config
        @config ||= Configuration.new
      end

      def configure
        yield config
      end

      def store
        config.store || raise(ConfigurationError, "No saga store configured, set Lepus::Saga.config.store")
      end

      def exchange_name = config.exchange_name

      def queue_name(partition)
        (partition.to_s == "default") ? "#{exchange_name}.execute" : "#{exchange_name}.execute.#{partition}"
      end

      def routing_key(partition) = "saga.execute.#{partition}"

      def registry
        @registry ||= {}
      end

      def register(name, klass)
        registry[name.to_s] = klass
      end

      # Every registered definition by saga name, after eager loading the
      # application so none is missing.
      def definitions
        eager_load_definitions!
        registry
      end

      def find_definition!(name)
        registry.fetch(name.to_s) do
          eager_load_definitions!
          registry.fetch(name.to_s) { raise UnknownSagaError, "Unknown saga #{name.inspect}" }
        end
      end

      # Re-enqueues a failed (or stuck) execution from its current step.
      # Bumps the epoch so stale in-flight messages from before the retry are
      # fenced out, and the attempt budget for the current step restarts.
      def retry(execution)
        ensure_retryable!(execution)

        store.with_lock(execution) do
          ensure_retryable!(execution)
          # A hand-driven retry is a fresh start: the stall clock and the
          # automatic resume budget both reset, or an abandoned execution would
          # be abandoned again on the next sweep.
          execution.record_progress
          store.update_execution(execution,
            epoch: execution.epoch + 1,
            status: execution.compensate_direction? ? "compensating" : "running",
            failure_reason: nil,
            **execution.reopen_attributes)
        end
        Instrumentation.saga_event("saga.resumed", execution)
        StepProducer.publish_step(execution)
        execution
      end

      # Forces compensation of a running or failed execution. Bumps the epoch
      # so in-flight execute messages are fenced out.
      def compensate(execution, reason: "manually compensated")
        ensure_not_terminal!(execution)

        store.with_lock(execution) do
          ensure_not_terminal!(execution)
          execution.epoch += 1
          Executor.begin_compensation(execution, reason: reason)
        end
        if execution.compensating?
          Instrumentation.saga_event("saga.compensation_started", execution)
          StepProducer.publish_step(execution)
        else
          Instrumentation.saga_event("saga.failed", execution)
        end
        execution
      end

      # Re-publishes the current step message for executions whose cursor has
      # stopped moving (lost message, dead worker). Safe to over-fire: the
      # executor acks anything already done.
      #
      # Staleness is measured from the last cursor move rather than from
      # `updated_at`, because a re-publish, a lock or an attempt opened and
      # abandoned all touch the row without the saga advancing — a wedged
      # execution kept resetting its own clock and was never selected here.
      #
      # While a partition's queue is backlogged its executions may simply be
      # waiting their turn: re-publishing them would only add duplicates and
      # spend their resume budget until the backlog alone got them abandoned.
      # So a backlogged execution is never abandoned, and is re-published only
      # once, after config.backlog_patience. Oldest stalls are handled first.
      #
      # Returns the number of executions re-published; abandoned ones are not
      # counted, they are failed.
      def resume_stuck(older_than: 15 * 60, limit: 100, max_resumes: config.max_resumes)
        resumed = handled = 0
        backlogged = Hash.new { |memo, partition| memo[partition] = QueueDepth.call(partition) > config.backlog_threshold }

        now = Time.now.utc
        store.stalled_executions(before: now - older_than).each do |execution|
          break if handled >= limit

          if backlogged[execution.partition]
            next unless execution.resume_count.zero? && execution.last_progress_at <= now - config.backlog_patience
          elsif execution.resume_count >= max_resumes
            handled += 1
            abandon_stalled(execution, max_resumes)
            next
          end

          handled += 1
          resume(execution)
          resumed += 1
        end
        resumed
      end

      private

      def ensure_retryable!(execution)
        return if %w[failed compensation_failed running compensating].include?(execution.status)

        raise NotRetryableError, "Cannot retry execution in status #{execution.status}"
      end

      def ensure_not_terminal!(execution)
        raise NotRetryableError, "Execution already terminal" if execution.terminal?
      end

      def resume(execution)
        resume_count = store.increment_resume_count(execution)
        Instrumentation.saga_event("saga.resumed", execution, resume_count: resume_count)
        StepProducer.publish_step(execution)
      end

      # Gives up on an execution that has been re-published max_resumes times
      # without the cursor moving: compensate what ran, otherwise fail it, so it
      # lands in a terminal state something can actually alert on.
      def abandon_stalled(execution, max_resumes)
        reason = "no progress after #{max_resumes} resume attempts"
        abandoned = false
        store.with_lock(execution) do
          next if execution.terminal?

          Executor.begin_compensation(execution, reason: reason)
          abandoned = true
        end
        return unless abandoned

        if execution.compensating?
          Instrumentation.saga_event("saga.compensation_started", execution, reason: reason)
          StepProducer.publish_step(execution)
        else
          Instrumentation.saga_event("saga.failed", execution, reason: reason)
        end
      end

      def eager_load_definitions!
        return if @definitions_loaded

        Rails.application.eager_load! if defined?(Rails.application) && Rails.application && !Rails.application.config.eager_load
        @definitions_loaded = true
      end
    end
  end
end
