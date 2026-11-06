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
      #
      # The query methods after #step_succeeded? are optional: they feed
      # read-only tools such as dashboards and are never called by the engine.
      # An adapter that implements them returns true from #queries? and runs
      # `it_behaves_like "a lepus saga query store"`.
      class Base
        QUERY_MAX_ROWS = 50_000
        MAX_SERIES_BUCKETS = 1_000
        GROUPABLE = %i[saga_name status partition current_step].freeze
        SORTS = {started_at: :started_at, duration: :duration_ms, finished_at: :finished_at}.freeze
        NULLABLE_SORTS = %i[duration_ms finished_at].freeze
        DIRECTIONS = %i[desc asc].freeze
        SERIES_KEYS = ["started", *ExecutionBehaviour::TERMINAL_STATUSES].freeze
        LATENCY_STATUSES = %w[succeeded failed].freeze
        PERCENTILES = {p50: 50, p95: 95, p99: 99}.freeze

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

        # Executions of a resource, most recently started first (ties by id,
        # descending).
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

        # Names of the steps each of `executions` ran forward (attempts in the
        # execute direction, whatever their status), as a Hash keyed by
        # execution id, every id present. Stores override it to read them in
        # one query.
        def executed_steps(executions)
          executions.to_h do |execution|
            [execution.id, step_attempts(execution).select { |attempt| attempt.direction == "execute" }.map(&:step_name).uniq]
          end
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

        # Whether the optional query methods below are implemented.
        def queries? = false

        # Executions matching the filters, at most `limit` of them, in the
        # order of `sort` and `direction`:
        #
        # - `sort: :started_at` (the default), `:duration` (duration_ms) or
        #   `:finished_at`, `direction: :desc` (the default) or `:asc`. The id
        #   breaks ties in the same direction. Executions without a value
        #   (in-progress ones have no duration_ms or finished_at) come last in
        #   either direction, by id. Ids need not follow time: rows written
        #   with ids that are not time-ordered (e.g. random UUIDv4) still list
        #   in time order.
        # - `after` is the id of the last execution of the previous page: the
        #   page holds the executions strictly after it, by (sort value, id),
        #   in the same order. An `after` that names no execution returns an
        #   empty page.
        #
        # Every filter is optional: `saga_name`, `status` and `current_step`
        # take a value or a list; `partition` matches the partition column,
        # and executions without one whose definition runs in that partition;
        # `resource` is a case-insensitive substring of resource_type or
        # resource_id; `from` (inclusive) and `to` (exclusive) bound
        # started_at, `progress_from` and `progress_to` bound
        # last_progress_at and `finished_from` and `finished_to` bound
        # finished_at the same way (in-progress executions with
        # `progress_to: Time.now.utc - 15 * 60` are the stalled ones).
        # `error_class` and `error_step` take a value or a list and keep
        # executions with a failed attempt of that error class and at that
        # step (either filter alone matches on its own attribute);
        # `error_from` (inclusive) and `error_to` (exclusive) bound that
        # failed attempt's started_at, the window #failure_summary counts.
        def list_executions(sort: :started_at, direction: :desc, after: nil, limit: 50, saga_name: nil, status: nil, current_step: nil,
          partition: nil, resource: nil, from: nil, to: nil, progress_from: nil, progress_to: nil, finished_from: nil, finished_to: nil,
          error_class: nil, error_step: nil, error_from: nil, error_to: nil)
          raise NotImplementedError
        end

        # Number of executions matching the #list_executions filters, as a
        # Hash keyed by the value of `group_by` (one of GROUPABLE), or by an
        # Array of values when `group_by` is an Array. Grouping by partition
        # resolves executions without one to their definition's partition
        # (nil for an unknown saga).
        def count_executions(group_by:, saga_name: nil, status: nil, current_step: nil, partition: nil, resource: nil, from: nil, to: nil,
          progress_from: nil, progress_to: nil, finished_from: nil, finished_to: nil, error_class: nil, error_step: nil, error_from: nil,
          error_to: nil)
          raise NotImplementedError
        end

        # Executions that finished between `from` (inclusive) and `to`
        # (exclusive), latest finish first (ties by id), at most `per_saga`
        # of each saga when given and at most `limit` in all. `saga_name`
        # takes a value or a list. Returns `{executions: [...], counts:
        # {[saga_name, status] => n}}`, the counts covering every execution
        # that finished in the window, so a caller can tell how many the
        # limits left out. `listed_from` (at most `from`) widens the listed
        # executions, not the counts, back to that time, so a caller polling
        # with some overlap can catch late writes without counting them
        # twice. Built on #list_executions and #count_executions.
        def finished_executions(from:, to:, listed_from: nil, saga_name: nil, per_saga: nil, limit: 100)
          counts = count_executions(group_by: %i[saga_name status], saga_name: saga_name, finished_from: from, finished_to: to)
          window = {saga_name: saga_name, finished_from: [listed_from, from].compact.min, finished_to: to}
          names = (per_saga && listed_from.nil?) ? counts.keys.map(&:first).uniq : nil
          executions = if per_saga
            (names || saga_names_finished(**window)).sort.flat_map do |name|
              list_executions(**window, saga_name: name, sort: :finished_at, limit: [per_saga, limit].min)
            end
          else
            list_executions(**window, sort: :finished_at, limit: limit)
          end
          ordered = executions.sort_by { |execution| [execution.finished_at.to_r, execution.id] }.reverse
          {executions: ordered.first(limit), counts: counts}
        end

        # Executions started (by started_at) and finished in each terminal
        # status (by finished_at) per `bucket` seconds between `from` and
        # `to`. Returns `{rows: [[bucket_start, {"started" => n, "completed" =>
        # n, ...}], ...], truncated:}` with every bucket of the window, bucket
        # starts aligned to multiples of `bucket` since the epoch. At most
        # `max_rows` of the newest timestamps of each kind are counted;
        # `truncated` tells whether some were left out.
        def execution_series(from:, to:, bucket:, saga_name: nil, max_rows: QUERY_MAX_ROWS)
          raise NotImplementedError
        end

        # Duration percentiles (nearest rank, in milliseconds) of the
        # succeeded and failed attempts started between `from` and `to`, per
        # saga, step and direction. Returns `{rows: [{saga_name:, step_name:,
        # direction:, count:, p50:, p95:, p99:, max:}, ...], truncated:}`
        # sorted by saga, step and direction, computed from at most `max_rows`
        # of the newest attempts.
        def step_latency(from:, to:, saga_name: nil, max_rows: QUERY_MAX_ROWS)
          raise NotImplementedError
        end

        # Failed attempts started between `from` and `to`, grouped by error
        # class, saga and step, most frequent first (then most recently seen),
        # at most `limit` groups. Returns `[{error_class:, saga_name:,
        # step_name:, count:, execution_count:, last_seen_at:,
        # sample_message:, sample_execution_id:}, ...]` where count is the
        # failed attempts, execution_count the distinct executions they belong
        # to and the sample the group's latest failure.
        def failure_summary(from:, to:, saga_name: nil, limit: 20)
          raise NotImplementedError
        end

        # The distinct saga names in storage, sorted.
        def saga_names
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

        # The column and direction of a #list_executions order, and whether
        # rows without a value can match: never for finished_at when a
        # finished_at bound is among the filters.
        def list_order(sort, direction, filters = {})
          column = SORTS[sort.to_s.to_sym] || raise(ArgumentError, "Cannot sort executions by #{sort.inspect}")
          descending = direction.to_s.to_sym
          raise ArgumentError, "Unknown sort direction #{direction.inspect}" unless DIRECTIONS.include?(descending)

          bounded = column == :finished_at && (filters[:finished_from] || filters[:finished_to])
          [column, descending == :desc, NULLABLE_SORTS.include?(column) && !bounded]
        end

        def saga_names_finished(**window)
          count_executions(group_by: :saga_name, **window).keys
        end

        def filter_values(value)
          values = Array(value).map(&:to_s)
          values unless values.empty?
        end

        def partition_saga_names(partition)
          Lepus::Saga.definitions.filter_map { |name, definition| name if definition.partition == partition.to_s }
        end

        def resolve_partition(partition, saga_name)
          partition || Lepus::Saga.definitions[saga_name]&.partition
        end

        def group_keys(group_by)
          keys = Array(group_by).map(&:to_sym)
          unknown = keys - GROUPABLE
          raise ArgumentError, "Cannot group executions by #{unknown.join(", ")}" if keys.empty? || unknown.any?

          keys
        end

        # Sums `[attributes, count]` rows into the #count_executions Hash.
        def tally_groups(rows, group_by)
          keys = group_keys(group_by)
          rows.each_with_object(Hash.new(0)) do |(attributes, count), counts|
            values = keys.map do |key|
              (key == :partition) ? resolve_partition(attributes[:partition], attributes[:saga_name]) : attributes[key]
            end
            counts[group_by.is_a?(Array) ? values : values.first] += count
          end
        end

        # `rows` holds up to max_rows + 1 entries, newest first.
        def take_rows(rows, max_rows)
          [rows.first(max_rows), rows.size > max_rows]
        end

        def series_bucket(from, to, bucket)
          seconds = bucket.to_i
          raise ArgumentError, "bucket must be at least one second" unless seconds.positive?
          if series_size(from, to, seconds) > MAX_SERIES_BUCKETS
            raise ArgumentError, "More than #{MAX_SERIES_BUCKETS} buckets between #{from} and #{to}"
          end

          seconds
        end

        def series_size(from, to, seconds)
          ((to.to_r - from.to_i.div(seconds) * seconds) / seconds).ceil
        end

        # Buckets `started` timestamps and `[finished_at, status]` pairs.
        def build_series(from, to, seconds, started, finished)
          first = from.to_i.div(seconds) * seconds
          rows = Array.new(series_size(from, to, seconds)) do |index|
            [Time.at(first + index * seconds).utc, SERIES_KEYS.to_h { |key| [key, 0] }]
          end
          started.each { |time| rows[(time.to_i - first).div(seconds)].last["started"] += 1 }
          finished.each { |time, status| rows[(time.to_i - first).div(seconds)].last[status] += 1 }
          rows
        end

        # Percentiles of `[saga_name, step_name, direction, duration_ms]` samples.
        def latency_rows(samples)
          samples.group_by { |sample| sample.first(3) }.sort_by(&:first).map do |(saga_name, step_name, direction), group|
            durations = group.map { |sample| sample.last.to_f }.sort
            {
              saga_name: saga_name, step_name: step_name, direction: direction, count: durations.size,
              **PERCENTILES.transform_values { |rank| durations[(Rational(rank, 100) * durations.size).ceil - 1] },
              max: durations.last
            }
          end
        end
      end
    end
  end
end
