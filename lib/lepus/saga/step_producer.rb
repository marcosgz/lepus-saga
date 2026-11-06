# frozen_string_literal: true

module Lepus
  module Saga
    # Publishes step messages on the configured saga exchange. The producer is
    # (re)configured on first use and whenever config.exchange_name changes.
    class StepProducer < Lepus::Producer
      use(:json)

      class << self
        def definition
          exchange = Lepus::Saga.exchange_name
          unless @definition&.exchange_name == exchange
            configure(exchange: {name: exchange, type: :topic}, publish: {persistent: true})
          end
          @definition
        end

        def publish_step(execution)
          publish(
            {
              execution_id: execution.id,
              saga: execution.saga_name,
              step: execution.current_step,
              direction: execution.direction,
              epoch: execution.epoch
            },
            routing_key: Lepus::Saga.routing_key(execution.partition),
            correlation_id: execution.correlation_id || execution.id,
            message_id: SecureRandom.uuid_v7,
            headers: {"x-saga-name" => execution.saga_name}
          )
        end
      end
    end
  end
end
