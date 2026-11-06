# frozen_string_literal: true

module Lepus
  module Saga
    module Stores
      # The persistence contract the engine runs on. An adapter subclasses it,
      # implements every method that raises NotImplementedError and returns
      # its own records: an execution record includes
      # Lepus::Saga::ExecutionBehaviour and a step attempt record includes
      # Lepus::Saga::StepAttemptBehaviour. Both need readers and writers for
      # their behaviour's ATTRIBUTES and `[](name)` returning the raw stored
      # value.
      #
      # Concurrency model: an execution is only changed while its row is held
      # by #with_lock or #with_locked_execution (an exclusive lock held until
      # the block returns, like SELECT ... FOR UPDATE inside a transaction).
      # The only writes made without it are #increment_resume_count, which
      # must be atomic in storage, and #save_step_attempt on an attempt the
      # caller opened itself.
      #
      # `require "lepus/saga/rspec"` and `it_behaves_like "a lepus saga store"`
      # verify an adapter against this contract.
      class Base
        # Inserts an execution and returns its record. `attributes` holds
        # saga_name, resource_type, resource_id, current_step, context,
        # correlation_id, partition, started_at and last_progress_at. The store
        # generates the id (a UUIDv7 string) and defaults status to "running",
        # direction to "execute", epoch and resume_count to 0 and context to {}.
        def create_execution(attributes)
          raise NotImplementedError
        end

        # The execution with this id, or nil. Never locks.
        def find_execution(id)
          raise NotImplementedError
        end

        # Persists every attribute of `execution` and returns it.
        def save_execution(execution)
          raise NotImplementedError
        end

        # Holds an exclusive lock on the execution's row for the duration of
        # the block, after reloading `execution` in place from storage. Writes
        # made in the block are atomic: they are kept when the block returns
        # (including through `next`) and discarded when it raises. Another
        # caller locking the same execution waits until the block finishes.
        # Returns the block's value.
        def with_lock(execution)
          raise NotImplementedError
        end

        # Same guarantees as #with_lock, starting from an id: yields a freshly
        # loaded, locked record, or nil when there is no such execution.
        # Returns the block's value.
        def with_locked_execution(id)
          execution = find_execution(id)
          return yield(nil) unless execution

          with_lock(execution) { yield execution }
        end

        # Adds one to the stored resume_count in a single atomic write (never a
        # read-modify-write of the record, so it cannot clobber or be clobbered
        # by a concurrent locked update) and touches updated_at. Sets the
        # record's resume_count and returns the stored value.
        def increment_resume_count(execution)
          raise NotImplementedError
        end

        # Executions in progress (running or compensating) whose
        # last_progress_at is before `before`, oldest last_progress_at first.
        # Returns an Enumerable; the caller stops iterating when done.
        def stalled_executions(before:)
          raise NotImplementedError
        end

        # Executions of a resource, most recently created first.
        def executions_for_resource(resource_type, resource_id)
          raise NotImplementedError
        end

        # Inserts a step attempt of `execution` and returns its record.
        # `attributes` holds step_name, direction, epoch, attempt and
        # started_at; status defaults to "running" and context_after to {}.
        # (execution, step_name, direction, epoch, attempt) is unique: a second
        # insert raises Lepus::Saga::DuplicateAttemptError, and raising it out
        # of #with_lock discards the block's other writes.
        def create_step_attempt(execution, attributes)
          raise NotImplementedError
        end

        # Persists every attribute of `attempt` and returns it.
        def save_step_attempt(attempt)
          raise NotImplementedError
        end

        # Attempts of an execution ordered by started_at, then created_at.
        def step_attempts(execution)
          raise NotImplementedError
        end

        # Number of attempts of `execution` for this step, direction and epoch,
        # whatever their status.
        def count_step_attempts(execution, step_name:, direction:, epoch:)
          raise NotImplementedError
        end

        # Whether a "running" attempt for this step, direction and epoch
        # started at or after `started_since`.
        def running_step_attempt?(execution, step_name:, direction:, epoch:, started_since:)
          raise NotImplementedError
        end

        # "running" attempts for this step, direction and epoch that started
        # before `started_before`.
        def stale_step_attempts(execution, step_name:, direction:, epoch:, started_before:)
          raise NotImplementedError
        end

        # Whether the step ever succeeded in the execute direction, in any
        # epoch.
        def step_succeeded?(execution, step_name)
          raise NotImplementedError
        end

        def update_execution(execution, attributes)
          assign(execution, attributes)
          save_execution(execution)
        end

        def update_step_attempt(attempt, attributes)
          assign(attempt, attributes)
          save_step_attempt(attempt)
        end

        def finish_step_attempt(attempt, status, context_after: {}, error: nil)
          update_step_attempt(attempt, attempt.finish_attributes(status, context_after: context_after, error: error))
        end

        private

        def assign(record, attributes)
          attributes.each { |name, value| record.public_send(:"#{name}=", value) }
        end
      end
    end
  end
end
