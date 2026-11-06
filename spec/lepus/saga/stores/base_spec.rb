# frozen_string_literal: true

RSpec.describe Lepus::Saga::Stores::Base do
  let(:store) { described_class.new }

  it "does not support the optional queries" do
    expect(store.queries?).to be(false)
  end

  it "raises NotImplementedError from the query methods" do
    expect { store.list_executions }.to raise_error(NotImplementedError)
    expect { store.count_executions(group_by: :status) }.to raise_error(NotImplementedError)
    expect { store.execution_series(from: 1.hour.ago, to: Time.current, bucket: 60) }.to raise_error(NotImplementedError)
    expect { store.step_latency(from: 1.hour.ago, to: Time.current) }.to raise_error(NotImplementedError)
    expect { store.failure_summary(from: 1.hour.ago, to: Time.current) }.to raise_error(NotImplementedError)
    expect { store.saga_names }.to raise_error(NotImplementedError)
  end
end
