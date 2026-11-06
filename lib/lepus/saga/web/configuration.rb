# frozen_string_literal: true

module Lepus
  module Saga
    module Web
      class Configuration
        ACTIONS = %i[read retry compensate].freeze
        POLL_INTERVALS = [0, 2, 5, 15, 60].freeze

        # Called with the Rack env and one of ACTIONS; a falsy result answers
        # 403. Allows everything by default.
        attr_accessor :authorize

        # Hides the retry and compensate actions and refuses their requests.
        attr_accessor :read_only

        attr_accessor :title

        # Seconds between refreshes until the viewer picks another interval
        # (one of POLL_INTERVALS; 0 turns polling off).
        attr_accessor :default_poll_interval

        # Cap on the rows read for the throughput series and step latency.
        attr_accessor :max_rows

        def initialize
          @authorize = ->(_env, _action) { true }
          @read_only = false
          @title = "Sagas"
          @default_poll_interval = 5
          @max_rows = Stores::Base::QUERY_MAX_ROWS
        end

        def allowed?(env, action)
          return false if read_only && action != :read

          authorize.call(env, action) ? true : false
        end

        def store = Lepus::Saga.store
      end
    end
  end
end
