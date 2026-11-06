# frozen_string_literal: true

# The contract every store must meet. The including group defines `store`
# and starts each example with empty storage:
#
#   RSpec.describe MyStore do
#     let(:store) { described_class.new }
#
#     it_behaves_like "a lepus saga store"
#   end
#
# Pass `concurrency: false` for a backend that cannot be shared by threads
# (an in-memory SQLite database, for example) to skip the threaded examples.
RSpec.shared_examples "a lepus saga store" do |concurrency: true|
  def create_execution(**attributes)
    store.create_execution({
      saga_name: "store_contract.saga",
      resource_type: "Resource",
      resource_id: "resource-1",
      current_step: "first",
      context: {"key" => "value"},
      correlation_id: nil,
      partition: nil,
      started_at: Time.current,
      last_progress_at: Time.current
    }.merge(attributes))
  end

  def create_attempt(execution, **attributes)
    store.create_step_attempt(execution, {
      step_name: "first", direction: "execute", epoch: 0, attempt: 1, started_at: Time.current
    }.merge(attributes))
  end

  def concurrently(count, &block)
    Array.new(count) { |index| Thread.new(index, &block) }.each(&:join)
  end

  let(:uuid_v7) { /\A\h{8}-\h{4}-7\h{3}-\h{4}-\h{12}\z/ }

  describe "#create_execution" do
    it "returns a record with the execution behaviour and a uuid v7 id" do
      execution = create_execution

      expect(execution).to be_a(Lepus::Saga::ExecutionBehaviour)
      expect(execution.id).to match(uuid_v7)
    end

    it "applies the defaults" do
      execution = store.find_execution(create_execution.id)

      expect(execution).to have_attributes(
        status: "running", direction: "execute", epoch: 0, resume_count: 0,
        failure_reason: nil, finished_at: nil
      )
      expect(execution.created_at).to be_within(1).of(Time.current)
      expect(execution.updated_at).to be_within(1).of(Time.current)
    end

    it "stores the given attributes" do
      started_at = 1.minute.ago
      execution = create_execution(
        resource_id: "resource-9", correlation_id: "corr-1", partition: "priority",
        context: {"nested" => {"list" => [1, "two"]}}, started_at: started_at
      )

      expect(store.find_execution(execution.id)).to have_attributes(
        saga_name: "store_contract.saga", resource_type: "Resource", resource_id: "resource-9",
        current_step: "first", correlation_id: "corr-1",
        context: {"nested" => {"list" => [1, "two"]}}
      )
      expect(store.find_execution(execution.id)[:partition]).to eq("priority")
      expect(store.find_execution(execution.id).started_at).to be_within(1).of(started_at)
    end

    it "defaults context to an empty hash" do
      execution = store.create_execution(
        saga_name: "store_contract.saga", resource_type: "Resource", resource_id: "1",
        current_step: "first", started_at: Time.current, last_progress_at: Time.current
      )

      expect(store.find_execution(execution.id).context).to eq({})
    end

    it "keeps a nil partition raw" do
      execution = store.find_execution(create_execution.id)

      expect(execution[:partition]).to be_nil
    end
  end

  describe "#find_execution" do
    it "returns nil for an unknown id" do
      expect(store.find_execution(SecureRandom.uuid_v7)).to be_nil
    end

    it "returns a copy unaffected by unsaved changes" do
      execution = create_execution
      execution.status = "failed"
      execution.context["key"] = "changed"

      expect(store.find_execution(execution.id)).to have_attributes(status: "running", context: {"key" => "value"})
    end
  end

  describe "#save_execution" do
    it "persists every changed attribute" do
      execution = create_execution
      execution.status = "compensating"
      execution.direction = "compensate"
      execution.current_step = "second"
      execution.epoch = 2
      execution.failure_reason = "boom " * 100
      execution.context = {"after" => true}
      execution.finished_at = Time.current

      expect(store.save_execution(execution)).to eq(execution)
      expect(store.find_execution(execution.id)).to have_attributes(
        status: "compensating", direction: "compensate", current_step: "second", epoch: 2,
        failure_reason: "boom " * 100, context: {"after" => true}
      )
    end

    it "persists a context changed in place" do
      execution = create_execution
      execution.context["added"] = 1

      store.save_execution(execution)

      expect(store.find_execution(execution.id).context).to eq("key" => "value", "added" => 1)
    end
  end

  describe "#update_execution" do
    it "assigns and persists the attributes" do
      execution = create_execution

      store.update_execution(execution, status: "failed", finished_at: Time.current)

      expect(execution.status).to eq("failed")
      expect(store.find_execution(execution.id).status).to eq("failed")
    end
  end

  describe "#with_lock" do
    it "reloads the record in place before yielding it" do
      execution = create_execution
      store.update_execution(store.find_execution(execution.id), epoch: 3)

      store.with_lock(execution) { |locked| expect(locked).to equal(execution) }

      expect(execution.epoch).to eq(3)
    end

    it "returns the block's value" do
      expect(store.with_lock(create_execution) { :value }).to eq(:value)
    end

    it "keeps the block's writes when it returns" do
      execution = create_execution

      store.with_lock(execution) do
        store.update_execution(execution, status: "completed")
        next :done
      end

      expect(store.find_execution(execution.id).status).to eq("completed")
    end

    it "discards the block's writes when it raises" do
      execution = create_execution

      expect {
        store.with_lock(execution) do
          store.update_execution(execution, status: "completed")
          create_attempt(execution)
          raise ArgumentError, "rolled back"
        end
      }.to raise_error(ArgumentError, "rolled back")

      expect(store.find_execution(execution.id).status).to eq("running")
      expect(store.step_attempts(execution)).to be_empty
    end

    if concurrency
      it "makes a second locker wait until the first finishes" do
        execution = create_execution
        events = Queue.new
        entered = Queue.new
        release = Queue.new

        holder = Thread.new do
          store.with_lock(store.find_execution(execution.id)) do
            entered << true
            release.pop
            events << :first_done
          end
        end
        entered.pop
        waiter = Thread.new { store.with_lock(store.find_execution(execution.id)) { events << :second_in } }
        sleep 0.3
        events << :released
        release << true
        [holder, waiter].each(&:join)

        expect(Array.new(events.size) { events.pop }).to eq(%i[released first_done second_in])
      end
    end
  end

  describe "#with_locked_execution" do
    it "yields a freshly loaded record" do
      execution = create_execution
      store.update_execution(store.find_execution(execution.id), current_step: "second")

      store.with_locked_execution(execution.id) do |locked|
        expect(locked).to be_a(Lepus::Saga::ExecutionBehaviour)
        expect(locked.current_step).to eq("second")
      end
    end

    it "yields nil for an unknown id" do
      expect(store.with_locked_execution(SecureRandom.uuid_v7) { |locked| [:yielded, locked] }).to eq([:yielded, nil])
    end

    it "discards the block's writes when it raises" do
      execution = create_execution

      expect {
        store.with_locked_execution(execution.id) do |locked|
          store.update_execution(locked, epoch: 1)
          raise ArgumentError
        end
      }.to raise_error(ArgumentError)

      expect(store.find_execution(execution.id).epoch).to eq(0)
    end

    if concurrency
      it "serializes concurrent read-modify-write cycles" do
        execution = create_execution

        concurrently(4) do
          3.times do
            store.with_locked_execution(execution.id) do |locked|
              epoch = locked.epoch
              sleep 0.005
              store.update_execution(locked, epoch: epoch + 1)
            end
          end
        end

        expect(store.find_execution(execution.id).epoch).to eq(12)
      end
    end
  end

  describe "#increment_resume_count" do
    it "adds one, updates the record and returns the stored value" do
      execution = create_execution

      expect(store.increment_resume_count(execution)).to eq(1)
      expect(execution.resume_count).to eq(1)
      expect(store.increment_resume_count(execution)).to eq(2)
      expect(store.find_execution(execution.id).resume_count).to eq(2)
    end

    it "increments the stored value, not the record's stale one" do
      stale = create_execution
      store.with_locked_execution(stale.id) do |locked|
        store.update_execution(locked, resume_count: 3, status: "completed")
      end

      expect(store.increment_resume_count(stale)).to eq(4)
      expect(store.find_execution(stale.id)).to have_attributes(resume_count: 4, status: "completed")
    end

    it "touches updated_at" do
      execution = create_execution
      before = store.find_execution(execution.id).updated_at
      sleep 0.01

      store.increment_resume_count(execution)

      expect(store.find_execution(execution.id).updated_at).to be > before
    end

    if concurrency
      it "loses no increment under concurrency" do
        execution = create_execution

        concurrently(4) { 5.times { store.increment_resume_count(store.find_execution(execution.id)) } }

        expect(store.find_execution(execution.id).resume_count).to eq(20)
      end

      def increment_during_locked_update(execution)
        entered = Queue.new
        release = Queue.new
        holder = Thread.new do
          store.with_lock(store.find_execution(execution.id)) do |locked|
            store.update_execution(locked, status: "failed")
            entered << true
            release.pop
            store.update_execution(locked, failure_reason: "locked update")
            yield if block_given?
          end
        rescue ArgumentError
          nil
        end
        entered.pop
        incrementer = Thread.new { store.increment_resume_count(store.find_execution(execution.id)) }
        sleep 0.1
        release << true
        [holder, incrementer].each(&:join)
      end

      it "is not clobbered by a concurrent locked update" do
        execution = create_execution

        increment_during_locked_update(execution)

        expect(store.find_execution(execution.id)).to have_attributes(resume_count: 1, status: "failed", failure_reason: "locked update")
      end

      it "is not undone when a concurrent locked update rolls back" do
        execution = create_execution

        increment_during_locked_update(execution) { raise ArgumentError, "rolled back" }

        expect(store.find_execution(execution.id)).to have_attributes(resume_count: 1, status: "running")
      end
    end
  end

  describe "#stalled_executions" do
    it "returns in-progress executions stalled before the cutoff, oldest first" do
      newer = create_execution(last_progress_at: 20.minutes.ago)
      oldest = create_execution(last_progress_at: 2.hours.ago)
      compensating = create_execution(last_progress_at: 1.hour.ago)
      store.update_execution(compensating, status: "compensating", direction: "compensate")

      stalled = store.stalled_executions(before: 15.minutes.ago).to_a

      expect(stalled.map(&:id)).to eq([oldest.id, compensating.id, newer.id])
      expect(stalled).to all(be_a(Lepus::Saga::ExecutionBehaviour))
    end

    it "skips executions that progressed recently or are terminal" do
      create_execution(last_progress_at: 1.minute.ago)
      Lepus::Saga::ExecutionBehaviour::TERMINAL_STATUSES.each do |status|
        store.update_execution(create_execution(last_progress_at: 1.hour.ago), status: status)
      end

      expect(store.stalled_executions(before: 15.minutes.ago).to_a).to be_empty
    end

    it "can be cut short by the caller" do
      ids = Array.new(3) { |index| create_execution(last_progress_at: (index + 1).hours.ago).id }

      expect(store.stalled_executions(before: Time.current).first(2).map(&:id)).to eq(ids.last(2).reverse)
    end
  end

  describe "#executions_for_resource" do
    it "returns the resource's executions, newest first" do
      older = create_execution(resource_id: "r-1")
      sleep 0.01
      newer = create_execution(resource_id: "r-1")
      create_execution(resource_id: "r-2")
      create_execution(resource_type: "Other", resource_id: "r-1")

      expect(store.executions_for_resource("Resource", "r-1").map(&:id)).to eq([newer.id, older.id])
    end
  end

  describe "#create_step_attempt" do
    let(:execution) { create_execution }

    it "returns a running attempt of the execution" do
      attempt = create_attempt(execution, attempt: 2, epoch: 1, direction: "compensate")

      expect(attempt).to be_a(Lepus::Saga::StepAttemptBehaviour)
      expect(attempt.id).to match(uuid_v7)
      expect(store.step_attempts(execution).sole).to have_attributes(
        id: attempt.id, saga_execution_id: execution.id, step_name: "first", direction: "compensate",
        epoch: 1, attempt: 2, status: "running", context_after: {}, finished_at: nil
      )
    end

    it "raises DuplicateAttemptError for the same step, direction, epoch and attempt" do
      create_attempt(execution)

      expect { create_attempt(execution) }.to raise_error(Lepus::Saga::DuplicateAttemptError)
      expect(store.step_attempts(execution).size).to eq(1)
    end

    it "accepts the same attempt number in another epoch, direction, step or execution" do
      create_attempt(execution)
      create_attempt(execution, epoch: 1)
      create_attempt(execution, direction: "compensate")
      create_attempt(execution, step_name: "second")
      create_attempt(create_execution)

      expect(store.step_attempts(execution).size).to eq(4)
    end

    it "discards the lock block's writes when a duplicate is raised out of it" do
      create_attempt(execution)

      expect {
        store.with_locked_execution(execution.id) do |locked|
          store.update_execution(locked, status: "failed")
          create_attempt(locked, attempt: 2)
          create_attempt(locked)
        end
      }.to raise_error(Lepus::Saga::DuplicateAttemptError)

      expect(store.find_execution(execution.id).status).to eq("running")
      expect(store.step_attempts(execution).map(&:attempt)).to eq([1])
    end
  end

  describe "#finish_step_attempt" do
    let(:execution) { create_execution }

    it "closes the attempt with its context and duration" do
      attempt = create_attempt(execution, started_at: 2.seconds.ago)

      store.finish_step_attempt(attempt, "succeeded", context_after: {"out" => 1})

      expect(store.step_attempts(execution).sole).to have_attributes(
        status: "succeeded", context_after: {"out" => 1}, error_class: nil, error_message: nil, error_backtrace: nil
      )
      expect(store.step_attempts(execution).sole.finished_at).to be_within(1).of(Time.current)
      expect(store.step_attempts(execution).sole.duration_ms).to be_within(1000).of(2000)
    end

    it "records the error" do
      attempt = create_attempt(execution)
      error = begin
        raise ArgumentError, "bad input " * 50
      rescue => raised
        raised
      end

      store.finish_step_attempt(attempt, "failed", error: error)

      expect(store.step_attempts(execution).sole).to have_attributes(
        status: "failed", error_class: "ArgumentError", error_message: "bad input " * 50
      )
      expect(store.step_attempts(execution).sole.error_backtrace).to include("store_examples.rb")
    end
  end

  describe "#step_attempts" do
    it "orders the execution's attempts by start time" do
      execution = create_execution
      later = create_attempt(execution, step_name: "second", started_at: 1.minute.ago)
      earlier = create_attempt(execution, step_name: "first", started_at: 2.minutes.ago)
      create_attempt(create_execution)

      expect(store.step_attempts(execution).map(&:id)).to eq([earlier.id, later.id])
    end
  end

  describe "current step queries" do
    let(:execution) { create_execution }
    let(:scope) { {step_name: "first", direction: "execute", epoch: 0} }

    before do
      store.finish_step_attempt(create_attempt(execution, attempt: 1, started_at: 20.minutes.ago), "failed")
      create_attempt(execution, attempt: 2, started_at: 10.minutes.ago)
      create_attempt(execution, attempt: 3, started_at: 1.minute.ago)
      create_attempt(execution, epoch: 1, started_at: 1.minute.ago)
      create_attempt(execution, direction: "compensate", started_at: 10.minutes.ago)
      create_attempt(execution, step_name: "second", started_at: 10.minutes.ago)
    end

    it "counts the attempts of the step, direction and epoch" do
      expect(store.count_step_attempts(execution, **scope)).to eq(3)
      expect(store.count_step_attempts(execution, **scope, epoch: 1)).to eq(1)
      expect(store.count_step_attempts(execution, **scope, step_name: "third")).to eq(0)
    end

    it "finds a running attempt started since the cutoff" do
      expect(store.running_step_attempt?(execution, **scope, started_since: 5.minutes.ago)).to be(true)
      expect(store.running_step_attempt?(execution, **scope, started_since: 30.seconds.ago)).to be(false)
      expect(store.running_step_attempt?(execution, **scope, direction: "compensate", started_since: 5.minutes.ago)).to be(false)
    end

    it "lists running attempts started before the cutoff" do
      stale = store.stale_step_attempts(execution, **scope, started_before: 5.minutes.ago).to_a

      expect(stale.map(&:attempt)).to eq([2])
      expect(stale).to all(be_a(Lepus::Saga::StepAttemptBehaviour))
    end

    it "tells whether a step ever succeeded in the execute direction" do
      expect(store.step_succeeded?(execution, "first")).to be(false)

      store.finish_step_attempt(store.step_attempts(execution).find { |a| a.direction == "compensate" }, "succeeded")
      expect(store.step_succeeded?(execution, "first")).to be(false)

      store.finish_step_attempt(store.step_attempts(execution).find { |a| a.epoch == 1 }, "succeeded")
      expect(store.step_succeeded?(execution, "first")).to be(true)
      expect(store.step_succeeded?(execution, "second")).to be(false)
    end
  end
end
