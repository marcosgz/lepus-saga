# frozen_string_literal: true

module SagaHelpers
  def saga_exchange
    Lepus::Testing.exchange(Lepus::Saga.exchange_name)
  end

  def drain
    Lepus::Saga::Testing.drain(consumer: SagaExecutorConsumer)
  end

  def order
    @order ||= Order.create!(name: "Order Two")
  end
end
