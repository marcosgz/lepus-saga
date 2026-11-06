# frozen_string_literal: true

module Lepus
  module Saga
    # Signal exceptions raised by step code to control the execution flow.
    # They are caught by the Executor and never bubble out of it.
    module Control
      class Signal < StandardError
        attr_reader :reason

        def initialize(reason = nil)
          @reason = reason
          super(reason || self.class.name.demodulize.downcase)
        end
      end

      # Skip the current step (success-equivalent) and continue with the next.
      class Skip < Signal; end

      # Finish the whole execution successfully right now (fast-path).
      class Complete < Signal; end

      # Permanent business failure: no retries, compensate immediately.
      class Fail < Signal; end
    end
  end
end
