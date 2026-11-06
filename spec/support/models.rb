# frozen_string_literal: true

Order = Struct.new(:id, :name) do
  class << self
    def create!(name:)
      new(SecureRandom.uuid_v7, name).tap { |order| records[order.id] = order }
    end

    def find(id) = records.fetch(id)

    def records = @records ||= {}

    def clear! = records.clear
  end
end

class SagaExecutorConsumer < Lepus::Saga::ExecutorConsumer
  saga_partition "default"
end
