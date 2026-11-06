# frozen_string_literal: true

module Lepus
  module Saga
    # Persistence adapters. Each one subclasses Stores::Base and lives at
    # "lepus/saga/stores/<name>", which is how `config.store = :<name>` finds
    # it, whether it ships with this gem (Memory) or in its own gem
    # (lepus-saga-active_record ships Stores::ActiveRecord).
    module Stores
      autoload :Base, "lepus/saga/stores/base"
      autoload :Memory, "lepus/saga/stores/memory"

      class << self
        def build(value)
          case value
          when nil then nil
          when Symbol, String then lookup(value).new
          when Class then value.new
          else value
          end
        end

        def lookup(name)
          const_name = name.to_s.camelize
          require "lepus/saga/stores/#{name.to_s.underscore}" unless const_defined?(const_name, false)
          const_get(const_name, false)
        rescue LoadError, NameError => error
          raise ConfigurationError, "Unknown saga store #{name.inspect} (#{error.message})"
        end
      end
    end
  end
end
