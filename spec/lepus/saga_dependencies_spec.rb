# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe Lepus::Saga do
  let(:lib) { File.expand_path("../../lib", __dir__) }

  def run_ruby(script)
    Open3.capture2e(RbConfig.ruby, "-rbundler/setup", "-I", lib, "-e", script)
  end

  it "loads every component without ActiveSupport core extensions or ActiveJob" do
    output, status = run_ruby(<<~RUBY)
      require "lepus/saga"
      require "lepus/saga/web"
      require "lepus/saga/testing"
      Lepus::Saga.config.store = :memory
      (Lepus::Saga.constants - [:ResumeStuckJob]).each { |name| Lepus::Saga.const_get(name) }
      Lepus::Saga::Web.constants.each { |name| Lepus::Saga::Web.const_get(name) }
      abort "ResumeStuckJob loaded" unless Lepus::Saga.autoload?(:ResumeStuckJob)
      abort "ActiveJob loaded" if defined?(ActiveJob)
      abort "Integer#minutes defined" if Integer.method_defined?(:minutes)
      abort "Object#blank? defined" if Object.method_defined?(:blank?)
      abort "Time.current defined" if Time.respond_to?(:current)
    RUBY

    expect(status).to be_success, output
  end

  it "does not load ActiveSupport", :without_active_support do
    output, status = run_ruby(<<~RUBY)
      require "lepus/saga"
      exit(defined?(ActiveSupport) ? 1 : 0)
    RUBY

    expect(status).to be_success, output
    expect(defined?(ActiveSupport)).to be_nil
  end
end
