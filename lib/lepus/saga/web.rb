# frozen_string_literal: true

require "json"
require "rack"
require_relative "../saga"

module Lepus
  module Saga
    # A Rack console for saga executions, mountable anywhere:
    #
    #   mount Lepus::Saga::Web => "/sagas"     # Rails routes
    #   run Lepus::Saga::Web                   # config.ru
    #
    # It reads through the store's query methods and acts through
    # Lepus::Saga.retry and Lepus::Saga.compensate. Mount it behind the host's
    # authentication; `config.authorize` adds per-action checks on top.
    module Web
      ROOT = File.expand_path("../../../web", __dir__)

      autoload :Api, "lepus/saga/web/api"
      autoload :Configuration, "lepus/saga/web/configuration"
      autoload :Guard, "lepus/saga/web/guard"
      autoload :Serializer, "lepus/saga/web/serializer"
      autoload :Static, "lepus/saga/web/static"

      class << self
        def config
          @config ||= Configuration.new
        end

        def configure
          yield config
          @app = nil
        end

        def call(env)
          app.call(env)
        end

        def app
          @app ||= build(config)
        end

        def build(config)
          api = Api.new(config)
          static = Static.new(config)
          Rack::Builder.new do
            use Guard, config
            map("/api") { run api }
            map("/") { run static }
          end.to_app
        end

        def reset!
          @config = nil
          @app = nil
        end
      end
    end
  end
end
