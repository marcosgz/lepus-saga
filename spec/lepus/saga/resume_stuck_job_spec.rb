# frozen_string_literal: true

RSpec.describe "Lepus::Saga::ResumeStuckJob", :active_support do
  subject(:job) { Lepus::Saga::ResumeStuckJob }

  it "resumes executions stalled for the given minutes" do
    allow(Lepus::Saga).to receive(:resume_stuck).and_return(0)

    job.perform_now(30)

    expect(Lepus::Saga).to have_received(:resume_stuck).with(older_than: 1800)
  end

  it "defaults to fifteen minutes" do
    allow(Lepus::Saga).to receive(:resume_stuck).and_return(0)

    job.perform_now

    expect(Lepus::Saga).to have_received(:resume_stuck).with(older_than: 900)
  end
end
