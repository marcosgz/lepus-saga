# frozen_string_literal: true

module Lepus
  module Saga
    # Abstract base for the generic step-executor consumer. The host app
    # declares one concrete subclass per partition:
    #
    #   class SagaExecutorConsumer < Lepus::Saga::ExecutorConsumer
    #     saga_partition "default", worker: { name: "saga", threads: 1 }
    #   end
    #
    # The exchange and queue names come from Lepus::Saga.config, so configure
    # it before the consumer classes load.
    class ExecutorConsumer < Lepus::Consumer
      self.abstract_class = true

      use(:json)

      def self.saga_partition(name = "default", worker: {name: "default", threads: 1}, retry_delay: 10_000)
        configure(
          worker: worker,
          queue: Lepus::Saga.queue_name(name),
          exchange: {name: Lepus::Saga.exchange_name, type: :topic},
          routing_key: Lepus::Saga.routing_key(name),
          retry_queue: {delay: retry_delay},
          error_queue: true
        )
      end

      def perform(message)
        case Executor.new(message.payload).run
        when :retry then reject!
        else ack!
        end
      end
    end
  end
end
