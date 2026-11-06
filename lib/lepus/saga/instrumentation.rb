# frozen_string_literal: true

module Lepus
  module Saga
    # All engine events go through Lepus.instrument, which appends the
    # ".lepus" suffix — subscribe with e.g. "saga.completed.lepus" or
    # /^saga\./ via ActiveSupport::Notifications.
    module Instrumentation
      EVENTS = %w[
        saga.started
        saga.step.started
        saga.step.finished
        saga.step.failed
        saga.step.skipped
        saga.completed
        saga.compensation_started
        saga.compensated
        saga.failed
        saga.compensation_failed
        saga.resumed
      ].freeze

      def self.saga_event(name, execution, step: nil, attempt: nil, error: nil, **extra)
        Lepus.instrument(
          name,
          execution: execution,
          saga_name: execution.saga_name,
          resource_type: execution.resource_type,
          resource_id: execution.resource_id,
          status: execution.status,
          step: step,
          attempt: attempt,
          direction: execution.direction,
          error_class: error&.class&.name,
          error_message: error&.message,
          **extra
        )
      end
    end
  end
end
