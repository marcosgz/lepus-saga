# frozen_string_literal: true

module Lepus
  module Saga
    # What the engine expects of a step attempt record, whatever stores it.
    # Adapters include it into their step attempt class.
    module StepAttemptBehaviour
      ATTRIBUTES = %i[
        id saga_execution_id step_name direction epoch attempt status
        error_class error_message error_backtrace context_after started_at
        finished_at duration_ms created_at updated_at
      ].freeze

      STATUSES = %w[running succeeded failed skipped].freeze

      STATUSES.each do |value|
        define_method(:"#{value}?") { status == value }
      end

      # The attributes that close this attempt with `status`.
      def finish_attributes(status, context_after: {}, error: nil)
        now = Time.now.utc
        {
          status: status,
          finished_at: now,
          duration_ms: (now - started_at) * 1000.0,
          context_after: context_after,
          error_class: error&.class&.name,
          error_message: error&.message,
          error_backtrace: error&.backtrace&.first(20)&.join("\n")
        }
      end
    end
  end
end
