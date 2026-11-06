# frozen_string_literal: true

module Lepus
  module Saga
    RetryPolicy = Data.define(:attempts) do
      self::DEFAULT_ATTEMPTS = 3

      def self.build(options)
        case options
        when RetryPolicy then options
        when Hash then new(attempts: options.fetch(:attempts, self::DEFAULT_ATTEMPTS))
        when Integer then new(attempts: options)
        when nil then new(attempts: self::DEFAULT_ATTEMPTS)
        else raise ArgumentError, "Invalid retry policy: #{options.inspect}"
        end
      end
    end
  end
end
