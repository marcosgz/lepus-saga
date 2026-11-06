# frozen_string_literal: true

require "active_job"

module Lepus
  module Saga
    # Recurring job that heals stalled executions. Schedule it every few
    # minutes, e.g. in Solid Queue's config/recurring.yml:
    #
    #   saga_resume_stuck:
    #     class: Lepus::Saga::ResumeStuckJob
    #     schedule: every 5 minutes
    class ResumeStuckJob < ActiveJob::Base
      def perform(older_than_minutes = 15)
        Lepus::Saga.resume_stuck(older_than: older_than_minutes.minutes)
      end
    end
  end
end
