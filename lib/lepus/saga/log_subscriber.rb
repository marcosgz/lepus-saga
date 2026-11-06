# frozen_string_literal: true

module Lepus
  module Saga
    # Writes one line per engine event to Lepus.logger. Lepus logs each
    # delivery, but not which saga, step or resource it carried, nor a step
    # failure the executor handles itself.
    class LogSubscriber
      LEVELS = {
        "saga.step.started" => :debug,
        "saga.step.finished" => :debug,
        "saga.step.skipped" => :debug,
        "saga.step.failed" => :warn,
        "saga.failed" => :error,
        "saga.compensation_failed" => :error
      }.freeze

      ATTRIBUTES = %i[saga_name step attempt duration_ms status reason resume_count retries_exhausted].freeze

      def self.call(event, payload)
        Lepus.logger.public_send(LEVELS.fetch(event, :info)) { format(event, payload) }
      end

      def self.format(event, payload)
        attributes = {
          execution: payload[:execution]&.id,
          resource: "#{payload[:resource_type]}/#{payload[:resource_id]}",
          **payload.slice(*ATTRIBUTES),
          error: error(payload)
        }.compact

        "#{event} #{attributes.map { |key, value| "#{key}=#{value}" }.join(" ")}"
      end

      def self.error(payload)
        message = [payload[:error_class], payload[:error_message]].compact.join(": ")
        message unless message.empty?
      end
      private_class_method :error
    end
  end
end
