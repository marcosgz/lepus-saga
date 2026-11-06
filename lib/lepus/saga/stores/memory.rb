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
            @attempt_ids = {}
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
          @mutex.synchronize { attempt_rows(execution.id) }.map { |row| StepAttempt.new(copy(row)) }
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

        def queries? = true

        def list_executions(before_id: nil, limit: 50, **filters)
          executions = matching_executions(**filters)
          executions = executions.select { |execution| execution.id < before_id } if before_id
          executions.sort_by(&:id).reverse.first(limit)
        end

        def count_executions(group_by:, **filters)
          tally_groups(matching_executions(**filters).map { |execution| [execution.attributes, 1] }, group_by)
        end

        def execution_series(from:, to:, bucket:, saga_name: nil, max_rows: QUERY_MAX_ROWS)
          seconds = series_bucket(from, to, bucket)
          window = from...to
          executions = matching_executions(saga_name: saga_name)
          started, started_truncated = take_rows(
            executions.map(&:created_at).select { |time| window.cover?(time) }.sort.reverse, max_rows
          )
          finished, finished_truncated = take_rows(
            executions.select { |execution| execution.terminal? && window.cover?(execution.finished_at) }
              .map { |execution| [execution.finished_at, execution.status] }.sort_by(&:first).reverse,
            max_rows
          )
          {rows: build_series(from, to, seconds, started, finished), truncated: started_truncated || finished_truncated}
        end

        def step_latency(from:, to:, saga_name: nil, max_rows: QUERY_MAX_ROWS)
          attempts = attempts_with_saga(from, to, saga_name).select do |attempt, _|
            attempt.status.in?(LATENCY_STATUSES) && attempt.duration_ms
          end
          samples, truncated = take_rows(
            attempts.sort_by { |attempt, _| attempt.started_at }.reverse
              .map { |attempt, saga| [saga, attempt.step_name, attempt.direction, attempt.duration_ms] },
            max_rows
          )
          {rows: latency_rows(samples), truncated: truncated}
        end

        def failure_summary(from:, to:, saga_name: nil, limit: 20)
          attempts_with_saga(from, to, saga_name).select { |attempt, _| attempt.failed? }
            .group_by { |attempt, saga| [attempt.error_class, saga, attempt.step_name] }
            .map { |(error_class, saga, step_name), group| failure_group(error_class, saga, step_name, group.map(&:first)) }
            .sort_by { |group| [-group[:count], -group[:last_seen_at].to_r] }
            .first(limit)
        end

        def saga_names
          @mutex.synchronize { @executions.each_value.map { |row| row[:saga_name] } }.uniq.sort
        end

        private

        def matching_executions(saga_name: nil, status: nil, current_step: nil, partition: nil, resource: nil, from: nil, to: nil,
          progress_from: nil, progress_to: nil, error_class: nil, error_step: nil, error_from: nil, error_to: nil)
          sagas = filter_values(saga_name)
          statuses = filter_values(status)
          steps = filter_values(current_step)
          partition_sagas = partition_saga_names(partition) if partition.present?
          needle = resource.to_s.downcase.presence
          failing = failing_execution_ids(filter_values(error_class), filter_values(error_step), error_from, error_to)
          where(@executions, Execution) do |row|
            (sagas.nil? || row[:saga_name].in?(sagas)) &&
              (statuses.nil? || row[:status].in?(statuses)) &&
              (steps.nil? || row[:current_step].in?(steps)) &&
              (from.nil? || row[:created_at] >= from) &&
              (to.nil? || row[:created_at] < to) &&
              (progress_from.nil? || row[:last_progress_at] >= progress_from) &&
              (progress_to.nil? || row[:last_progress_at] < progress_to) &&
              (failing.nil? || failing.include?(row[:id])) &&
              (partition_sagas.nil? || in_partition?(row, partition.to_s, partition_sagas)) &&
              (needle.nil? || row.values_at(:resource_type, :resource_id).any? { |value| value.to_s.downcase.include?(needle) })
          end
        end

        def failing_execution_ids(error_classes, steps, from, to)
          return if [error_classes, steps, from, to].all?(&:nil?)

          @mutex.synchronize do
            @step_attempts.each_value.filter_map do |row|
              next unless row[:status] == "failed"
              next unless error_classes.nil? || row[:error_class].in?(error_classes)
              next unless steps.nil? || row[:step_name].in?(steps)
              next if from && row[:started_at] < from
              next if to && row[:started_at] >= to

              row[:saga_execution_id]
            end.to_set
          end
        end

        def in_partition?(row, partition, saga_names)
          row[:partition] ? row[:partition] == partition : row[:saga_name].in?(saga_names)
        end

        # Attempts started in the window as `[attempt, saga_name]` pairs.
        def attempts_with_saga(from, to, saga_name)
          sagas = @mutex.synchronize { @executions.transform_values { |row| row[:saga_name] } }
          wanted = filter_values(saga_name)
          where(@step_attempts, StepAttempt) do |row|
            (from...to).cover?(row[:started_at]) && (wanted.nil? || sagas[row[:saga_execution_id]].in?(wanted))
          end.map { |attempt| [attempt, sagas[attempt.saga_execution_id]] }
        end

        def failure_group(error_class, saga_name, step_name, attempts)
          latest = attempts.max_by { |attempt| [attempt.finished_at, attempt.id] }
          {
            error_class: error_class, saga_name: saga_name, step_name: step_name, count: attempts.size,
            execution_count: attempts.map(&:saga_execution_id).uniq.size, last_seen_at: latest.finished_at, sample_message: latest.error_message,
            sample_execution_id: latest.saga_execution_id
          }
        end

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
            if unique && attempt_rows(row[:saga_execution_id]).any? { |other| other.values_at(*unique) == row.values_at(*unique) }
              raise DuplicateAttemptError, "Duplicate #{row.slice(*unique).inspect}"
            end

            log_undo(table, row[:id])
            table[row[:id]] = row
            (@attempt_ids[row[:saga_execution_id]] ||= []) << row[:id] if table.equal?(@step_attempts)
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

        # Attempt rows of an execution through the index kept on insert; ids of
        # rows a rollback removed are skipped. Call it holding @mutex.
        def attempt_rows(execution_id)
          @attempt_ids.fetch(execution_id, []).filter_map { |id| @step_attempts[id] }
        end

        def copy(row)
          row.to_h { |name, value| [name, name.in?(JSON_ATTRIBUTES) ? JSON.parse(JSON.generate(value)) : value] }
        end
      end
    end
  end
end
