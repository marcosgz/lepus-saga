# frozen_string_literal: true

module Lepus
  module Saga
    Step = Data.define(:name, :compensate, :retry_policy) do
      def compensatable? = !compensate.to_s.strip.empty?
    end
  end
end
