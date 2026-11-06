# frozen_string_literal: true

# The optional query contract (see Lepus::Saga::Stores::Base#queries?). The
# including group defines `store` and starts each example with empty storage:
#
#   RSpec.describe MyStore do
#     let(:store) { described_class.new }
#
#     it_behaves_like "a lepus saga query store"
#   end
RSpec.shared_examples "a lepus saga query store" do
  let(:checkout) { "query_examples.orders_checkout" }
  let(:invoice) { "query_examples.invoices_issue" }
  let(:hour) { Time.at(Time.current.to_i.div(3600) * 3600).utc - 3.hours }

  before do
    stub_const("LepusSagaQueryCheckout", Class.new(Lepus::Saga::Definition) do
      saga_name "query_examples.orders_checkout"

      step :reserve
      step :charge
      step :ship
    end)
    stub_const("LepusSagaQueryInvoice", Class.new(Lepus::Saga::Definition) do
      saga_name "query_examples.invoices_issue"
      partition "billing"

      step :render
      step :deliver
    end)
  end

  def query_execution(saga_name: checkout, status: "running", created_at: hour, finished_at: nil, **attributes)
    execution = store.create_execution({
      saga_name: saga_name, resource_type: "Order", resource_id: "order-1", current_step: "reserve",
      partition: nil, started_at: created_at, last_progress_at: created_at
    }.merge(attributes))
    store.update_execution(execution, status: status, created_at: created_at, finished_at: finished_at)
  end

  def query_attempt(execution, step_name: "charge", attempt: 1, direction: "execute", status: "succeeded",
    started_at: hour, duration_ms: 100.0, **attributes)
    record = store.create_step_attempt(execution, {
      step_name: step_name, direction: direction, epoch: 0, attempt: attempt, started_at: started_at
    })
    store.update_step_attempt(record, {
      status: status, duration_ms: duration_ms, finished_at: duration_ms && started_at + duration_ms / 1000.0
    }.merge(attributes))
  end

  it "supports queries" do
    expect(store.queries?).to be(true)
  end

  describe "#list_executions" do
    it "returns execution records, newest id first" do
      ids = Array.new(3) { query_execution.id }

      executions = store.list_executions

      expect(executions).to all(be_a(Lepus::Saga::ExecutionBehaviour))
      expect(executions.map(&:id)).to eq(ids.sort.reverse)
    end

    it "pages with limit and before_id" do
      ids = Array.new(5) { query_execution.id }.sort.reverse

      first_page = store.list_executions(limit: 2)
      second_page = store.list_executions(limit: 2, before_id: first_page.last.id)
      last_page = store.list_executions(limit: 2, before_id: second_page.last.id)

      expect([first_page, second_page, last_page].map { |page| page.map(&:id) }).to eq(ids.each_slice(2).to_a)
    end

    it "filters by saga name and status, single or listed" do
      running = query_execution
      failed = query_execution(status: "failed", finished_at: hour)
      invoice_failed = query_execution(saga_name: invoice, status: "failed", finished_at: hour)
      query_execution(saga_name: invoice, status: "completed", finished_at: hour)

      expect(store.list_executions(saga_name: checkout).map(&:id)).to contain_exactly(running.id, failed.id)
      expect(store.list_executions(status: "failed").map(&:id)).to contain_exactly(failed.id, invoice_failed.id)
      expect(store.list_executions(saga_name: [checkout], status: %w[running failed]).map(&:id))
        .to contain_exactly(running.id, failed.id)
      expect(store.list_executions(saga_name: [], status: nil).size).to eq(4)
    end

    it "filters by current step, single or listed" do
      reserving = query_execution(current_step: "reserve")
      charging = query_execution(current_step: "charge")
      query_execution(current_step: "ship")

      expect(store.list_executions(current_step: "reserve").map(&:id)).to contain_exactly(reserving.id)
      expect(store.list_executions(current_step: %w[reserve charge]).map(&:id)).to contain_exactly(reserving.id, charging.id)
      expect(store.count_executions(group_by: :status, current_step: "charge")).to eq("running" => 1)
    end

    it "matches the partition column or, without one, the definition's partition" do
      default = query_execution
      invoice_default = query_execution(saga_name: invoice)
      checkout_billing = query_execution(partition: "billing")

      expect(store.list_executions(partition: "billing").map(&:id)).to contain_exactly(invoice_default.id, checkout_billing.id)
      expect(store.list_executions(partition: "default").map(&:id)).to contain_exactly(default.id)
      expect(store.list_executions(partition: :priority)).to be_empty
    end

    it "searches resource type and id case-insensitively" do
      order = query_execution(resource_type: "Order", resource_id: "ORD-100")
      invoice_record = query_execution(resource_type: "Invoice", resource_id: "inv-7")

      expect(store.list_executions(resource: "ord-1").map(&:id)).to contain_exactly(order.id)
      expect(store.list_executions(resource: "voice").map(&:id)).to contain_exactly(invoice_record.id)
      expect(store.list_executions(resource: "or").map(&:id)).to contain_exactly(order.id)
    end

    it "treats LIKE wildcards in the resource search literally" do
      query_execution(resource_id: "order-100")
      percent = query_execution(resource_id: "100%")
      underscore = query_execution(resource_id: "a_b")
      query_execution(resource_id: "axb")

      expect(store.list_executions(resource: "100%").map(&:id)).to contain_exactly(percent.id)
      expect(store.list_executions(resource: "a_b").map(&:id)).to contain_exactly(underscore.id)
    end

    it "bounds created_at by from (inclusive) and to (exclusive)" do
      query_execution(created_at: hour - 1.minute)
      at_from = query_execution(created_at: hour)
      inside = query_execution(created_at: hour + 30.minutes)
      query_execution(created_at: hour + 1.hour)

      expect(store.list_executions(from: hour, to: hour + 1.hour).map(&:id)).to contain_exactly(at_from.id, inside.id)
      expect(store.list_executions(from: hour + 1.minute).size).to eq(2)
      expect(store.list_executions(to: hour).size).to eq(1)
    end
  end

  describe "#count_executions" do
    before do
      query_execution
      query_execution(status: "failed", finished_at: hour)
      query_execution(status: "failed", finished_at: hour, current_step: "charge")
      query_execution(saga_name: invoice, status: "completed", finished_at: hour, current_step: nil)
      query_execution(saga_name: invoice, partition: "priority")
      query_execution(saga_name: "query_examples.unregistered")
    end

    it "groups by one attribute" do
      expect(store.count_executions(group_by: :status)).to eq("running" => 3, "failed" => 2, "completed" => 1)
      expect(store.count_executions(group_by: :current_step)).to eq("reserve" => 4, "charge" => 1, nil => 1)
    end

    it "groups by several attributes under array keys" do
      expect(store.count_executions(group_by: %i[saga_name status])).to eq(
        [checkout, "running"] => 1, [checkout, "failed"] => 2,
        [invoice, "completed"] => 1, [invoice, "running"] => 1,
        ["query_examples.unregistered", "running"] => 1
      )
    end

    it "resolves executions without a partition to their definition's" do
      expect(store.count_executions(group_by: :partition)).to eq("default" => 3, "billing" => 1, "priority" => 1, nil => 1)
      expect(store.count_executions(group_by: %i[partition status])).to include(["default", "failed"] => 2)
    end

    it "applies the list filters" do
      expect(store.count_executions(group_by: :status, saga_name: checkout, status: %w[running failed]))
        .to eq("running" => 1, "failed" => 2)
      expect(store.count_executions(group_by: :saga_name, partition: "billing")).to eq(invoice => 1)
    end

    it "rejects unknown groupings" do
      expect { store.count_executions(group_by: :resource_id) }.to raise_error(ArgumentError)
    end
  end

  describe "#execution_series" do
    it "counts starts by created_at and terminal statuses by finished_at in aligned buckets" do
      query_execution(created_at: hour + 5.minutes)
      query_execution(created_at: hour + 10.minutes, status: "completed", finished_at: hour + 20.minutes)
      query_execution(created_at: hour - 1.hour, status: "failed", finished_at: hour + 70.minutes)
      query_execution(created_at: hour - 1.hour, status: "compensated", finished_at: hour - 1.minute)
      query_execution(created_at: hour + 15.minutes, status: "compensating")

      series = store.execution_series(from: hour + 10.minutes, to: hour + 2.hours, bucket: 1.hour)

      expect(series[:truncated]).to be(false)
      expect(series[:rows].map(&:first)).to eq([hour, hour + 1.hour])
      expect(series[:rows].map(&:last)).to eq([
        {"started" => 2, "completed" => 1, "compensated" => 0, "failed" => 0, "compensation_failed" => 0},
        {"started" => 0, "completed" => 0, "compensated" => 0, "failed" => 1, "compensation_failed" => 0}
      ])
    end

    it "keeps empty buckets and filters by saga" do
      query_execution(created_at: hour + 1.minute)
      query_execution(saga_name: invoice, created_at: hour + 2.minutes)

      series = store.execution_series(from: hour, to: hour + 30.minutes, bucket: 600, saga_name: invoice)

      expect(series[:rows].map(&:first)).to eq([hour, hour + 10.minutes, hour + 20.minutes])
      expect(series[:rows].map { |_, counts| counts["started"] }).to eq([1, 0, 0])
    end

    it "counts at most max_rows timestamps of each kind, newest first" do
      [1, 2, 61].each { |minute| query_execution(created_at: hour + minute.minutes) }

      series = store.execution_series(from: hour, to: hour + 2.hours, bucket: 1.hour, max_rows: 2)

      expect(series[:truncated]).to be(true)
      expect(series[:rows].map { |_, counts| counts["started"] }).to eq([1, 1])
    end

    it "rejects empty or too many buckets" do
      expect { store.execution_series(from: hour, to: hour + 1.hour, bucket: 0) }.to raise_error(ArgumentError)
      expect { store.execution_series(from: hour, to: hour + 1.day, bucket: 1) }.to raise_error(ArgumentError)
    end
  end

  describe "#step_latency" do
    it "computes nearest-rank percentiles per saga, step and direction" do
      execution = query_execution
      (1..20).each { |attempt| query_attempt(execution, attempt: attempt, duration_ms: attempt * 10.0) }
      query_attempt(execution, step_name: "reserve", direction: "compensate", status: "failed", duration_ms: 40.0)
      query_attempt(query_execution(saga_name: invoice), step_name: "render", duration_ms: 5.0)

      latency = store.step_latency(from: hour, to: hour + 1.hour)

      expect(latency[:truncated]).to be(false)
      expect(latency[:rows]).to eq([
        {saga_name: invoice, step_name: "render", direction: "execute", count: 1, p50: 5.0, p95: 5.0, p99: 5.0, max: 5.0},
        {saga_name: checkout, step_name: "charge", direction: "execute", count: 20, p50: 100.0, p95: 190.0, p99: 200.0, max: 200.0},
        {saga_name: checkout, step_name: "reserve", direction: "compensate", count: 1, p50: 40.0, p95: 40.0, p99: 40.0, max: 40.0}
      ])
    end

    it "leaves out running and skipped attempts, other sagas and attempts outside the window" do
      execution = query_execution
      query_attempt(execution, attempt: 1, duration_ms: 10.0)
      query_attempt(execution, attempt: 2, status: "running", duration_ms: nil)
      query_attempt(execution, attempt: 3, status: "skipped", duration_ms: 1.0)
      query_attempt(execution, attempt: 4, started_at: hour - 1.second, duration_ms: 500.0)
      query_attempt(execution, attempt: 5, started_at: hour + 1.hour, duration_ms: 500.0)
      query_attempt(query_execution(saga_name: invoice), step_name: "render", duration_ms: 5.0)

      rows = store.step_latency(from: hour, to: hour + 1.hour, saga_name: checkout)[:rows]

      expect(rows).to contain_exactly(include(step_name: "charge", count: 1, max: 10.0))
    end

    it "uses at most max_rows of the newest attempts" do
      execution = query_execution
      [10.0, 20.0, 30.0].each_with_index do |duration, index|
        query_attempt(execution, attempt: index + 1, started_at: hour + index.minutes, duration_ms: duration)
      end

      latency = store.step_latency(from: hour, to: hour + 1.hour, max_rows: 2)

      expect(latency[:truncated]).to be(true)
      expect(latency[:rows]).to contain_exactly(include(count: 2, p50: 20.0, max: 30.0))
    end
  end

  describe "#failure_summary" do
    it "groups failed attempts by error class, saga and step, most frequent first" do
      first = query_execution
      second = query_execution
      query_attempt(first, attempt: 1, status: "failed", started_at: hour + 1.minute,
        error_class: "Timeout::Error", error_message: "first timeout")
      query_attempt(second, attempt: 1, status: "failed", started_at: hour + 3.minutes,
        error_class: "Timeout::Error", error_message: "latest timeout")
      query_attempt(first, attempt: 2, status: "failed", started_at: hour + 2.minutes,
        error_class: "ArgumentError", error_message: "bad amount")
      query_attempt(first, step_name: "ship", status: "failed", started_at: hour + 4.minutes,
        error_class: "Timeout::Error", error_message: "ship timeout")
      query_attempt(first, attempt: 3, started_at: hour + 5.minutes)

      summary = store.failure_summary(from: hour, to: hour + 1.hour)

      expect(summary.first).to include(
        error_class: "Timeout::Error", saga_name: checkout, step_name: "charge", count: 2,
        sample_message: "latest timeout", sample_execution_id: second.id
      )
      expect(summary.first[:last_seen_at]).to be_within(0.01).of(hour + 3.minutes + 0.1)
      expect(summary.drop(1).map { |group| group.values_at(:error_class, :step_name, :count) })
        .to eq([["Timeout::Error", "ship", 1], ["ArgumentError", "charge", 1]])
    end

    it "filters by window and saga and caps the groups at limit" do
      execution = query_execution
      query_attempt(execution, attempt: 1, status: "failed", started_at: hour - 1.minute, error_class: "OldError")
      query_attempt(execution, attempt: 2, status: "failed", error_class: "KeyError")
      query_attempt(execution, step_name: "ship", status: "failed", started_at: hour + 1.minute, error_class: "IOError")
      query_attempt(query_execution(saga_name: invoice), step_name: "render", status: "failed", error_class: "KeyError")

      expect(store.failure_summary(from: hour, to: hour + 1.hour, saga_name: checkout).map { |group| group[:error_class] })
        .to eq(%w[IOError KeyError])
      expect(store.failure_summary(from: hour, to: hour + 1.hour, limit: 1).size).to eq(1)
    end

    it "is empty without failures" do
      query_attempt(query_execution)

      expect(store.failure_summary(from: hour, to: hour + 1.hour)).to eq([])
    end
  end

  describe "#saga_names" do
    it "lists the distinct saga names, sorted" do
      query_execution(saga_name: invoice)
      query_execution
      query_execution

      expect(store.saga_names).to eq([invoice, checkout])
    end
  end
end
