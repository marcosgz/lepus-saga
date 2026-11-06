# frozen_string_literal: true

require "bundler/setup"
require "logger"
require "lepus/saga"
require "lepus/saga/testing"
require "lepus/saga/rspec"
require "pry"

ACTIVE_SUPPORT = Gem.loaded_specs.key?("activesupport")

if ACTIVE_SUPPORT
  require "active_support"
  require "active_support/core_ext"
  require "lepus/saga/resume_stuck_job"
  ActiveJob::Base.logger = Logger.new(File::NULL)
end

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |file| require file }

Lepus.logger = Logger.new(File::NULL)
Lepus::Saga.configure { |config| config.store = :memory }

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.include SagaHelpers
  config.include Lepus::Saga::ExampleHelpers

  if ACTIVE_SUPPORT
    config.filter_run_excluding :without_active_support
  else
    config.filter_run_excluding :active_support
  end

  config.before do
    Lepus::Testing.enable!
    Lepus::Producers::Hooks.reset!
    Lepus::Testing.clear_all_messages!
  end

  config.after do
    Lepus::Testing.disable!
    Lepus::Saga.config.store&.clear!
    Order.clear!
  end
end
