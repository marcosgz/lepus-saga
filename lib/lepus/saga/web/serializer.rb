# frozen_string_literal: true

module Lepus
  module Saga
    module Web
      module Serializer
        EXECUTION_FIELDS = %i[
          id saga_name resource_type resource_id status current_step direction
          epoch correlation_id failure_reason resume_count duration_ms
        ].freeze
        EXECUTION_TIMES = %i[started_at finished_at last_progress_at created_at updated_at].freeze
        ATTEMPT_FIELDS = %i[
          id step_name direction epoch attempt status error_class error_message
          error_backtrace duration_ms
        ].freeze

        module_function

        def execution(record, context: false)
          data = EXECUTION_FIELDS.to_h { |name| [name, record.public_send(name)] }
          EXECUTION_TIMES.each { |name| data[name] = time(record.public_send(name)) }
          data[:partition] = partition(record)
          data[:context] = record.context if context
          data
        end

        # A finished execution and the steps it passed: `reached` is the
        # furthest step it ran forward and, on the compensation path,
        # `back_to` the last step it compensated (or failed compensating).
        def finished(record, executed)
          steps = Array(Lepus::Saga.definitions[record.saga_name]&.steps).map(&:name)
          reached = executed.max_by { |name| steps.index(name) || -1 } || record.current_step
          {
            id: record.id, saga_name: record.saga_name, status: record.status,
            started_at: time(record.started_at), finished_at: time(record.finished_at), duration_ms: record.duration_ms,
            reached: reached, back_to: (record.current_step if record.compensate_direction?)
          }
        end

        def attempt(record)
          data = ATTEMPT_FIELDS.to_h { |name| [name, record.public_send(name)] }
          data[:duration_ms] = data[:duration_ms]&.to_f&.round(1)
          data[:context_after] = record.context_after
          data[:started_at] = time(record.started_at)
          data[:finished_at] = time(record.finished_at)
          data
        end

        def definition(name, definition)
          {
            name: name,
            known: !definition.nil?,
            partition: definition&.partition,
            steps: Array(definition&.steps).map do |step|
              {name: step.name, compensate: step.compensate, attempts: step.retry_policy.attempts}
            end
          }
        end

        def time(value)
          value&.utc&.iso8601(3)
        end

        def partition(record)
          record.partition
        rescue UnknownSagaError
          record[:partition]
        end
      end
    end
  end
end
