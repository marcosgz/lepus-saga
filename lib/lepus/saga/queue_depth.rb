# frozen_string_literal: true

module Lepus
  module Saga
    # Messages ready in a partition's execute queue. Under fake publishing the
    # fake saga exchange stands in for the queue.
    module QueueDepth
      def self.call(partition)
        return fake_depth(partition) if defined?(Lepus::Testing) && Lepus::Testing.fake_publisher_enabled?

        Lepus.config.producer_config.with_connection do |connection|
          channel = connection.create_channel
          begin
            channel.queue(Saga.queue_name(partition), passive: true).message_count
          rescue Bunny::NotFound
            0
          ensure
            channel.close if channel.open?
          end
        end
      end

      def self.fake_depth(partition)
        Lepus::Testing.exchange(Saga.exchange_name).find_messages(routing_key: Saga.routing_key(partition)).size
      end
    end
  end
end
