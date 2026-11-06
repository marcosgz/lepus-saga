# frozen_string_literal: true

RSpec.describe Lepus::Saga::Configuration do
  subject(:config) { described_class.new }

  it "has defaults matching the engine's original constants" do
    expect(config).to have_attributes(
      exchange_name: "lepus.saga",
      max_resumes: 5,
      backlog_threshold: 100,
      backlog_patience: hours(2),
      stale_running_attempt_after: minutes(5),
      store: nil
    )
  end

  describe "#store=" do
    it "resolves a store name to a new instance of the store" do
      config.store = :memory

      expect(config.store).to be_a(Lepus::Saga::Stores::Memory)
    end

    it "accepts a store name as a string" do
      config.store = "memory"

      expect(config.store).to be_a(Lepus::Saga::Stores::Memory)
    end

    it "instantiates a store class" do
      config.store = Lepus::Saga::Stores::Memory

      expect(config.store).to be_a(Lepus::Saga::Stores::Memory)
    end

    it "keeps a store instance" do
      store = Lepus::Saga::Stores::Memory.new
      config.store = store

      expect(config.store).to equal(store)
    end

    it "requires lepus/saga/stores/<name> for stores defined elsewhere" do
      allow(Lepus::Saga::Stores).to receive(:require).with("lepus/saga/stores/custom_engine") do
        stub_const("Lepus::Saga::Stores::CustomEngine", Class.new(Lepus::Saga::Stores::Base))
      end

      config.store = :custom_engine

      expect(config.store).to be_a(Lepus::Saga::Stores::CustomEngine)
    end

    it "keeps plural store names as they are" do
      allow(Lepus::Saga::Stores).to receive(:require).with("lepus/saga/stores/redis") do
        stub_const("Lepus::Saga::Stores::Redis", Class.new(Lepus::Saga::Stores::Base))
      end

      config.store = :redis

      expect(config.store).to be_a(Lepus::Saga::Stores::Redis)
    end

    it "raises for an unknown store" do
      expect { config.store = :nope }.to raise_error(Lepus::Saga::ConfigurationError, /Unknown saga store :nope/)
    end
  end

  describe "Lepus::Saga.store" do
    it "raises when no store is configured" do
      allow(Lepus::Saga.config).to receive(:store).and_return(nil)

      expect { Lepus::Saga.store }.to raise_error(Lepus::Saga::ConfigurationError, /No saga store configured/)
    end
  end

  describe "Lepus::Saga.configure" do
    around do |example|
      previous = Lepus::Saga.config.exchange_name
      example.run
    ensure
      Lepus::Saga.config.exchange_name = previous
    end

    it "yields the global configuration" do
      Lepus::Saga.configure { |c| c.exchange_name = "app.saga" }

      expect(Lepus::Saga.exchange_name).to eq("app.saga")
    end

    it "names the default partition's queue without a suffix" do
      expect(Lepus::Saga.queue_name("default")).to eq("lepus.saga.execute")
    end

    it "names other partitions' queues with the partition suffix" do
      expect(Lepus::Saga.queue_name("organic")).to eq("lepus.saga.execute.organic")
    end

    it "names queues after the configured exchange" do
      Lepus::Saga.configure { |c| c.exchange_name = "app.saga" }

      expect(Lepus::Saga.queue_name("organic")).to eq("app.saga.execute.organic")
    end

    it "publishes step messages on the configured exchange" do
      Lepus::Saga.configure { |c| c.exchange_name = "app.saga" }
      execution = Lepus::Saga.store.create_execution(
        saga_name: "orders.checkout", resource_type: "Order", resource_id: "1",
        current_step: "persist_local", partition: "organic", started_at: Time.now.utc
      )

      Lepus::Saga::StepProducer.publish_step(execution)

      expect(Lepus::Testing.exchange("app.saga").find_messages(routing_key: "saga.execute.organic").size).to eq(1)
    end
  end
end
