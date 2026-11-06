# frozen_string_literal: true

module Lepus
  module Saga
    # What the engine expects of an execution record, whatever stores it.
    # Adapters include it into their execution class.
    module ExecutionBehaviour
      ATTRIBUTES = %i[
        id saga_name resource_type resource_id status current_step direction
        epoch context correlation_id failure_reason partition started_at
        finished_at last_progress_at resume_count created_at updated_at
      ].freeze

      STATUSES = %w[running completed compensating compensated failed compensation_failed].freeze
      TERMINAL_STATUSES = %w[completed compensated failed compensation_failed].freeze
      IN_PROGRESS_STATUSES = %w[running compensating].freeze
      DIRECTIONS = %w[execute compensate].freeze

      STATUSES.each do |value|
        define_method(:"#{value}?") { status == value }
      end

      def terminal? = TERMINAL_STATUSES.include?(status)

      def in_progress? = IN_PROGRESS_STATUSES.include?(status)

      def compensate_direction? = direction == "compensate"

      # The cursor moved, so the stall clock restarts and the resume budget is
      # spent fresh on the step we just reached.
      def record_progress
        self.last_progress_at = Time.now.utc
        self.resume_count = 0
      end

      def definition_class
        Lepus::Saga.find_definition!(saga_name)
      end

      def steps = definition_class.steps

      def partition = self[:partition] || definition_class.partition

      def current_step_definition
        definition_class.find_step!(current_step) if current_step
      end

      # Filters for the attempts of the step the cursor points at.
      def current_step_scope
        {step_name: current_step, direction: direction, epoch: epoch}
      end

      def duration
        (finished_at || Time.now.utc) - started_at
      end
    end
  end
end
