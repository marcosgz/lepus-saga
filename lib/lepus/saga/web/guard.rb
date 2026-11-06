# frozen_string_literal: true

module Lepus
  module Saga
    module Web
      # Refuses every request the `authorize` hook does not allow to read, and
      # adds the headers every response carries.
      class Guard
        HEADERS = {
          "x-content-type-options" => "nosniff",
          "referrer-policy" => "same-origin",
          "x-frame-options" => "SAMEORIGIN"
        }.freeze

        def initialize(app, config)
          @app = app
          @config = config
        end

        def call(env)
          status, headers, body = @config.allowed?(env, :read) ? @app.call(env) : forbidden(env)
          HEADERS.each { |name, value| headers[name] ||= value }
          [status, headers, body]
        end

        private

        def forbidden(env)
          if env["PATH_INFO"].to_s.start_with?("/api/")
            [403, {"content-type" => "application/json"}, [JSON.generate(error: "Forbidden")]]
          else
            [403, {"content-type" => "text/plain; charset=utf-8"}, ["Forbidden"]]
          end
        end
      end
    end
  end
end
