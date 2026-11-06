# frozen_string_literal: true

module Lepus
  module Saga
    # Helpers for the shared examples, which run with or without ActiveSupport.
    module ExampleHelpers
      def minutes(count) = count * 60

      def hours(count) = count * 3600

      def days(count) = count * 86_400

      def ago(seconds) = Time.now.utc - seconds

      def sole(records)
        records = records.to_a
        expect(records.size).to eq(1)
        records.first
      end
    end
  end
end
