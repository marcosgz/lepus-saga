# frozen_string_literal: true

module Lepus
  module Saga
    class Configuration
      # Topic exchange carrying step messages. Queues are named after it.
      attr_accessor :exchange_name

      # How many times resume_stuck re-publishes an execution that is not moving
      # before it gives up on it. Without a ceiling a wedged execution is
      # re-published every few minutes forever and stays "running": it never
      # reaches a failed state, so nothing watching for failures ever sees it.
      attr_accessor :max_resumes

      # Ready messages above which a partition's queue counts as backlogged.
      # A busy but healthy queue hands messages to consumers as they arrive and
      # rarely holds more than a few ready ones.
      attr_accessor :backlog_threshold

      # How long an execution may stall behind a backlog before resume_stuck
      # re-publishes it anyway (once), in case its message was lost meanwhile.
      attr_accessor :backlog_patience

      # A running attempt older than this is considered abandoned (worker died
      # or lost the message) and is closed as failed before a new one opens.
      attr_accessor :stale_running_attempt_after

      # Where executions and step attempts live (see Lepus::Saga::Stores::Base).
      attr_reader :store

      def initialize
        @exchange_name = "lepus.saga"
        @max_resumes = 5
        @backlog_threshold = 100
        @backlog_patience = 2.hours
        @stale_running_attempt_after = 5.minutes
        @store = nil
      end

      # Accepts a store instance, a store class, or the name of a store
      # (`:memory`, `:active_record`, ...) which is required from
      # "lepus/saga/stores/<name>" and resolved to Lepus::Saga::Stores::<Name>.
      def store=(value)
        @store = Stores.build(value)
      end
    end
  end
end
