# frozen_string_literal: true

require "lepus/testing"

module Lepus
  module Saga
    # Test-only helper to run saga step messages inline. Requires
    # Lepus::Testing fake publishing to be enabled.
    module Testing
      class DrainStallError < StandardError; end

      # Pops messages from the fake saga exchange and delivers them to the
      # executor consumer until the exchange is empty. Messages rejected for
      # retry are redelivered immediately (the TTL delay is irrelevant under
      # fake publishing), so retry loops run to their conclusion inline.
      def self.drain(consumer:, max_iterations: 50)
        exchange = Lepus::Testing.exchange(Lepus::Saga.exchange_name)
        iterations = 0

        until exchange.empty?
          if (iterations += 1) > max_iterations
            raise DrainStallError, "saga drain did not settle after #{max_iterations} iterations"
          end

          batch = exchange.messages.dup
          exchange.clear_messages
          batch.each do |message|
            result = Lepus::Testing.consumer_perform(consumer, {payload: message[:payload]})
            exchange.add_message(message) if result == :reject
          end
        end
      end
    end
  end
end
