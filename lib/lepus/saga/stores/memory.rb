# frozen_string_literal: true

require "json"
require "monitor"

module Lepus
  module Saga
    module Stores
      # Thread-safe in-process store for tests and single-process tools.
      # Records are copies: changing one changes nothing until it is saved, and
      # every read builds a fresh record. Locks are per execution and
      # re-entrant; writes made under a lock are undone when the block raises.
      # Readers see writes as soon as they happen (no isolation between
      # concurrent transactions), so it is not a database.
      class Memory < Base
        class RecordNotFound < StandardError; end

        ATTEMPT_KEY = %i[saga_execution_id step_name direction epoch attempt].freeze
        JSON_ATTRIBUTES = %i[context context_after].freeze

        class Record
          class << self
            attr_reader :attribute_names

            def attributes(*names)
              @attribute_names = names
              include(Module.new { attr_accessor(*names) })
            end
          end

          def initialize(values = {})
            load(values)
          end

          def [](name) = instance_variable_get(:"@#{name}")

          def attributes
            self.class.attribute_names.to_h { |name| [name, self[name]] }
          end

          def load(values)
            values.each { |name, value| instance_variable_set(:"@#{name}", value) }
            self
          end

          def ==(other) = other.instance_of?(self.class) && !id.nil? && other.id == id

          alias_method :eql?, :==

          def hash = [self.class, id].hash
        end

        class Execution < Record
          attributes(*ExecutionBehaviour::ATTRIBUTES)

          include ExecutionBehaviour
        end

        class StepAttempt < Record
          attributes(*StepAttemptBehaviour::ATTRIBUTES)

          include StepAttemptBehaviour
        end

        def initialize
          super
          @mutex = Mutex.new
          @transaction_key = :"lepus_saga_memory_transaction_#{object_id}"
          clear!
        end

        def clear!
          @mutex.synchronize do
            @executions = {}
            @step_attempts = {}
            @row_locks = Hash.new { |locks, id| locks[id] = Monitor.new }
          end
        end

        def create_execution(attributes)
          now = Time.current
          row = {
            status: "running", direction: "execute", epoch: 0, resume_count: 0,
            context: {}, last_progress_at: now, **attributes.symbolize_keys,
            id: SecureRandom.uuid_v7, created_at: now, updated_at: now
          }
          Execution.new(insert(@executions, row))
        end

        def find_execution(id)
          read(@executions, id)&.then { |row| Execution.new(row) }
        end

        def save_execution(execution)
          execution.updated_at = Time.current
          update(@executions, execution.attributes)
          execution
        end

        def with_lock(execution)
          row_lock(execution.id).synchronize do
            transaction do
              execution.load(read(@executions, execution.id) || raise(RecordNotFound, "No execution #{execution.id}"))
              yield execution
            end
          end
        end

        def with_locked_execution(id)
          row_lock(id).synchronize do
            transaction { yield find_execution(id) }
          end
        end

        def increment_resume_count(execution)
          row_lock(execution.id).synchronize do
            execution.resume_count = @mutex.synchronize do
              row = @executions.fetch(execution.id) { raise RecordNotFound, "No execution #{execution.id}" }
              log_undo(@executions, execution.id)
              @executions[execution.id] = row.merge(resume_count: row[:resume_count] + 1, updated_at: Time.current)
              row[:resume_count] + 1
            end
          end
        end

        def stalled_executions(before:)
          where(@executions, Execution) { |row| row[:status].in?(ExecutionBehaviour::IN_PROGRESS_STATUSES) && row[:last_progress_at] < before }
            .sort_by { |execution| [execution.last_progress_at, execution.id] }
        end

        def executions_for_resource(resource_type, resource_id)
          where(@executions, Execution) { |row| row[:resource_type] == resource_type && row[:resource_id] == resource_id }
            .sort_by { |execution| [execution.created_at, execution.id] }.reverse
        end

        def create_step_attempt(execution, attributes)
          now = Time.current
          row = {
            direction: "execute", epoch: 0, status: "running", context_after: {},
            **attributes.symbolize_keys,
            id: SecureRandom.uuid_v7, saga_execution_id: execution.id, created_at: now, updated_at: now
          }
          StepAttempt.new(insert(@step_attempts, row, unique: ATTEMPT_KEY))
        end

        def save_step_attempt(attempt)
          attempt.updated_at = Time.current
          update(@step_attempts, attempt.attributes)
          attempt
        end

        def step_attempts(execution)
          where(@step_attempts, StepAttempt) { |row| row[:saga_execution_id] == execution.id }
            .sort_by { |attempt| [attempt.started_at, attempt.created_at, attempt.id] }
        end

        def count_step_attempts(execution, step_name:, direction:, epoch:)
          attempts_for_step(execution, step_name, direction, epoch).size
        end

        def running_step_attempt?(execution, step_name:, direction:, epoch:, started_since:)
          attempts_for_step(execution, step_name, direction, epoch)
            .any? { |attempt| attempt.running? && attempt.started_at >= started_since }
        end

        def stale_step_attempts(execution, step_name:, direction:, epoch:, started_before:)
          attempts_for_step(execution, step_name, direction, epoch)
            .select { |attempt| attempt.running? && attempt.started_at < started_before }
        end

        def step_succeeded?(execution, step_name)
          step_attempts(execution).any? do |attempt|
            attempt.step_name == step_name && attempt.direction == "execute" && attempt.succeeded?
          end
        end

        private

        def attempts_for_step(execution, step_name, direction, epoch)
          step_attempts(execution).select do |attempt|
            attempt.step_name == step_name && attempt.direction == direction && attempt.epoch == epoch
          end
        end

        def row_lock(id)
          @mutex.synchronize { @row_locks[id] }
        end

        def transaction(&block)
          undo_log ? yield : run_transaction(&block)
        end

        def run_transaction
          log = Thread.current[@transaction_key] = []
          committed = false
          result = yield
          committed = true
          result
        ensure
          Thread.current[@transaction_key] = nil
          rollback(log) unless committed
        end

        def undo_log = Thread.current[@transaction_key]

        def log_undo(table, id)
          undo_log&.push([table, id, table[id]])
        end

        def rollback(log)
          @mutex.synchronize do
            log.reverse_each do |table, id, previous|
              previous ? table[id] = previous : table.delete(id)
            end
          end
        end

        def read(table, id)
          @mutex.synchronize { table[id] }&.then { |row| copy(row) }
        end

        def where(table, klass, &filter)
          @mutex.synchronize { table.values.select(&filter) }.map { |row| klass.new(copy(row)) }
        end

        def insert(table, row, unique: nil)
          row = copy(row)
          @mutex.synchronize do
            if unique && table.each_value.any? { |other| other.values_at(*unique) == row.values_at(*unique) }
              raise DuplicateAttemptError, "Duplicate #{row.slice(*unique).inspect}"
            end

            log_undo(table, row[:id])
            table[row[:id]] = row
          end
          copy(row)
        end

        def update(table, row)
          row = copy(row)
          @mutex.synchronize do
            raise RecordNotFound, "No record #{row[:id]}" unless table.key?(row[:id])

            log_undo(table, row[:id])
            table[row[:id]] = row
          end
        end

        def copy(row)
          row.to_h { |name, value| [name, name.in?(JSON_ATTRIBUTES) ? JSON.parse(JSON.generate(value)) : value] }
        end
      end
    end
  end
end
