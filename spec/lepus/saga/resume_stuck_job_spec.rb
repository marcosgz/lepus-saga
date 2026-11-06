# frozen_string_literal: true

RSpec.describe Lepus::Saga::ResumeStuckJob do
  it "resumes executions stalled for the given minutes" do
    allow(Lepus::Saga).to receive(:resume_stuck).and_return(0)

    described_class.perform_now(30)

    expect(Lepus::Saga).to have_received(:resume_stuck).with(older_than: 30.minutes)
  end

  it "defaults to fifteen minutes" do
    allow(Lepus::Saga).to receive(:resume_stuck).and_return(0)

    described_class.perform_now

    expect(Lepus::Saga).to have_received(:resume_stuck).with(older_than: 15.minutes)
  end
end
