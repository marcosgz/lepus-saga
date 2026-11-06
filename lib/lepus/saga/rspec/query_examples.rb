# frozen_string_literal: true

require_relative "helpers"

# The optional query contract (see Lepus::Saga::Stores::Base#queries?). The
# including group defines `store` and starts each example with empty storage:
#
#   RSpec.describe MyStore do
#     let(:store) { described_class.new }
#
#     it_behaves_like "a lepus saga query store"
#   end
RSpec.shared_examples "a lepus saga query store" do
  include Lepus::Saga::ExampleHelpers

  let(:checkout) { "query_examples.orders_checkout" }
  let(:invoice) { "query_examples.invoices_issue" }
  let(:hour) { Time.at(Time.now.utc.to_i.div(3600) * 3600).utc - hours(3) }

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

  def query_execution(saga_name: checkout, status: "running", created_at: hour, finished_at: nil, duration_ms: nil, **attributes)
    execution = store.create_execution({
      saga_name: saga_name, resource_type: "Order", resource_id: "order-1", current_step: "reserve",
      partition: nil, started_at: created_at, last_progress_at: created_at
    }.merge(attributes))
    store.update_execution(execution, status: status, created_at: created_at, finished_at: finished_at, duration_ms: duration_ms)
  end

  # Executions created in the order given, so their ids (time-ordered by
  # creation) do not follow their started_at.
  def started_at_minutes(*offsets, **attributes)
    offsets.map { |minute| query_execution(created_at: hour + minutes(minute), **attributes) }
  end

  def finished(duration_ms, created_at: hour, **attributes)
    query_execution(status: "completed", created_at: created_at, finished_at: created_at + duration_ms / 1000.0, duration_ms: duration_ms, **attributes)
  end

  def ids(executions) = executions.map(&:id)

  def all_pages(size, **options)
    pages = []
    after = nil
    loop do
      page = store.list_executions(**options, after: after, limit: size)
      break if page.empty?

      pages << ids(page)
      after = page.last.id
    end
    pages
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
    it "returns execution records, latest start first, whatever the ids" do
      executions = started_at_minutes(3, 0, 4, 1, 2)
      by_start = ids(executions.sort_by(&:started_at).reverse)

      expect(store.list_executions).to all(be_a(Lepus::Saga::ExecutionBehaviour))
      expect(ids(store.list_executions)).to eq(by_start)
      expect(ids(store.list_executions(sort: :started_at, direction: :asc))).to eq(by_start.reverse)
      expect(ids(store.list_executions(sort: "started_at", direction: "desc", limit: 2))).to eq(by_start.first(2))
    end

    it "breaks ties by id in the direction of the sort" do
      tied = ids(started_at_minutes(1, 1, 1)).sort
      later, earlier = started_at_minutes(2, 0)

      expect(ids(store.list_executions)).to eq([later.id, *tied.reverse, earlier.id])
      expect(ids(store.list_executions(direction: :asc))).to eq([earlier.id, *tied, later.id])
    end

    it "pages after the last execution shown, through ties, without gaps or repeats" do
      executions = started_at_minutes(2, 1, 1, 3, 1, 1, 0)

      [:desc, :asc].each do |direction|
        expected = ids(store.list_executions(direction: direction, limit: 100))
        pages = all_pages(2, direction: direction)

        expect(pages.flatten).to eq(expected)
        expect(pages.map(&:size)).to eq([2, 2, 2, 1])
        expect(expected).to match_array(ids(executions))
      end
    end

    it "sorts by duration with executions that have none last in either direction" do
      slow = finished(9_000)
      running = query_execution
      fast = finished(100)
      compensating = query_execution(status: "compensating")
      medium = finished(2_500)
      unfinished = [running, compensating].map(&:id).sort

      expect(ids(store.list_executions(sort: :duration))).to eq([slow.id, medium.id, fast.id, *unfinished.reverse])
      expect(ids(store.list_executions(sort: :duration, direction: :asc))).to eq([fast.id, medium.id, slow.id, *unfinished])
      expect(store.list_executions(sort: :duration, limit: 1).first.duration_ms).to eq(9_000)
    end

    it "pages by duration through ties and across executions without one" do
      [400, nil, 200, 400, nil, 100, 400, nil].each_with_index do |duration, index|
        duration ? finished(duration, created_at: hour + minutes(index)) : query_execution(created_at: hour + minutes(index))
      end

      page_sizes = [1, 2, 3, 5]
      {desc: [400, 400, 400, 200, 100, nil, nil, nil], asc: [100, 200, 400, 400, 400, nil, nil, nil]}.each do |direction, durations|
        listed = store.list_executions(sort: :duration, direction: direction, limit: 100)
        page_sizes.each do |size|
          expect(all_pages(size, sort: :duration, direction: direction).flatten).to eq(ids(listed))
        end
        expect(listed.map(&:duration_ms)).to eq(durations)
      end
    end

    it "pages after an execution the filters leave out by its sort value" do
      first, hidden, last = started_at_minutes(3, 2, 1)
      hidden = store.update_execution(hidden, status: "failed")

      expect(ids(store.list_executions(status: "running", after: hidden.id))).to eq([last.id])
      expect(ids(store.list_executions(status: "running", after: first.id))).to eq([last.id])
    end

    it "returns an empty page after an id that names no execution" do
      query_execution

      expect(store.list_executions(after: "00000000-0000-4000-8000-000000000000")).to eq([])
    end

    it "rejects unknown sorts and directions" do
      expect { store.list_executions(sort: :resource_id) }.to raise_error(ArgumentError)
      expect { store.list_executions(direction: :sideways) }.to raise_error(ArgumentError)
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

    it "bounds started_at by from (inclusive) and to (exclusive)" do
      query_execution(created_at: hour - minutes(1))
      at_from = query_execution(created_at: hour)
      inside = query_execution(created_at: hour + minutes(30))
      query_execution(created_at: hour + hours(1))

      expect(store.list_executions(from: hour, to: hour + hours(1)).map(&:id)).to contain_exactly(at_from.id, inside.id)
      expect(store.list_executions(from: hour + minutes(1)).size).to eq(2)
      expect(store.list_executions(to: hour).size).to eq(1)
    end
  end

  describe "finished filter" do
    it "bounds finished_at by finished_from (inclusive) and finished_to (exclusive)" do
      query_execution(status: "completed", finished_at: hour - 1)
      at_from = query_execution(status: "failed", finished_at: hour)
      inside = query_execution(status: "completed", finished_at: hour + minutes(30))
      query_execution(status: "completed", finished_at: hour + hours(1))
      query_execution

      expect(ids(store.list_executions(finished_from: hour, finished_to: hour + hours(1)))).to contain_exactly(at_from.id, inside.id)
      expect(store.count_executions(group_by: :status, finished_from: hour)).to eq("failed" => 1, "completed" => 2)
      expect(store.list_executions(finished_to: hour).size).to eq(1)
    end
  end

  describe "#finished_executions" do
    it "returns the executions that finished in the window, latest finish first, with counts by saga and status" do
      query_execution(status: "completed", finished_at: hour - 1)
      at_from = query_execution(status: "completed", finished_at: hour)
      failed = query_execution(status: "failed", finished_at: hour + minutes(2))
      compensated = query_execution(saga_name: invoice, status: "compensated", finished_at: hour + minutes(1))
      query_execution(status: "completed", finished_at: hour + minutes(5))
      query_execution

      result = store.finished_executions(from: hour, to: hour + minutes(5))

      expect(result[:executions]).to all(be_a(Lepus::Saga::ExecutionBehaviour))
      expect(ids(result[:executions])).to eq([failed.id, compensated.id, at_from.id])
      expect(result[:counts]).to eq([checkout, "completed"] => 1, [checkout, "failed"] => 1, [invoice, "compensated"] => 1)
    end

    it "keeps the latest per_saga of each saga and at most limit, counting every one" do
      checkouts = [4, 1, 3, 2].map { |minute| query_execution(status: "completed", finished_at: hour + minutes(minute)) }
      invoice_failed = query_execution(saga_name: invoice, status: "failed", finished_at: hour)
      window = {from: hour, to: hour + hours(1)}

      result = store.finished_executions(**window, per_saga: 2)

      expect(ids(result[:executions])).to eq([checkouts[0].id, checkouts[2].id, invoice_failed.id])
      expect(result[:counts]).to eq([checkout, "completed"] => 4, [invoice, "failed"] => 1)
      expect(ids(store.finished_executions(**window, limit: 2)[:executions])).to eq([checkouts[0].id, checkouts[2].id])
      expect(ids(store.finished_executions(**window, saga_name: [invoice])[:executions])).to eq([invoice_failed.id])
    end

    it "breaks finish ties by id, latest first" do
      tied = Array.new(3) { query_execution(status: "completed", finished_at: hour) }

      expect(ids(store.finished_executions(from: hour, to: hour + 1)[:executions])).to eq(ids(tied).sort.reverse)
    end

    it "is empty when nothing finished in the window" do
      query_execution

      expect(store.finished_executions(from: hour, to: hour + hours(1))).to eq(executions: [], counts: {})
    end

    it "lists, without counting, the executions that finished from listed_from" do
      before = query_execution(saga_name: invoice, status: "failed", finished_at: hour - minutes(1))
      query_execution(status: "completed", finished_at: hour - minutes(5))
      inside = query_execution(status: "completed", finished_at: hour + minutes(1))

      result = store.finished_executions(from: hour, to: hour + hours(1), listed_from: hour - minutes(2), per_saga: 5)

      expect(ids(result[:executions])).to eq([inside.id, before.id])
      expect(result[:counts]).to eq([checkout, "completed"] => 1)
    end
  end

  describe "#executed_steps" do
    it "names the steps each execution ran forward, keyed by id, every id present" do
      failed = query_execution(status: "failed")
      query_attempt(failed, step_name: "reserve")
      query_attempt(failed, step_name: "charge", status: "failed")
      query_attempt(failed, step_name: "charge", attempt: 2, status: "failed")
      compensated = query_execution(status: "compensated")
      query_attempt(compensated, step_name: "reserve")
      query_attempt(compensated, step_name: "reserve", direction: "compensate")
      untouched = query_execution

      steps = store.executed_steps([failed, compensated, untouched])

      expect(steps.keys).to contain_exactly(failed.id, compensated.id, untouched.id)
      expect(steps[failed.id]).to contain_exactly("reserve", "charge")
      expect(steps[compensated.id]).to eq(["reserve"])
      expect(steps[untouched.id]).to eq([])
      expect(store.executed_steps([])).to eq({})
    end
  end

  describe "progress and error filters" do
    it "bounds last_progress_at by progress_from (inclusive) and progress_to (exclusive)" do
      query_execution(last_progress_at: hour - minutes(1))
      at_from = query_execution(last_progress_at: hour)
      inside = query_execution(last_progress_at: hour + minutes(30))
      query_execution(last_progress_at: hour + hours(1), created_at: hour - hours(2))

      expect(store.list_executions(progress_from: hour, progress_to: hour + hours(1)).map(&:id)).to contain_exactly(at_from.id, inside.id)
      expect(store.list_executions(progress_to: hour).size).to eq(1)
      expect(store.count_executions(group_by: :status, progress_from: hour + minutes(1))).to eq("running" => 2)
    end

    it "keeps executions with a failed attempt of the error class and step" do
      timed_out = query_execution
      query_attempt(timed_out, attempt: 1, status: "failed", error_class: "Timeout::Error")
      query_attempt(timed_out, attempt: 2)
      shipped = query_execution
      query_attempt(shipped, step_name: "ship", status: "failed", error_class: "Timeout::Error")
      rejected = query_execution(status: "failed", finished_at: hour)
      query_attempt(rejected, status: "failed", error_class: "ArgumentError")
      recovered = query_execution
      query_attempt(recovered, error_class: "Timeout::Error")

      expect(store.list_executions(error_class: "Timeout::Error").map(&:id)).to contain_exactly(timed_out.id, shipped.id)
      expect(store.list_executions(error_class: "Timeout::Error", error_step: "charge").map(&:id)).to contain_exactly(timed_out.id)
      expect(store.list_executions(error_class: %w[Timeout::Error ArgumentError], error_step: ["charge"]).map(&:id))
        .to contain_exactly(timed_out.id, rejected.id)
      expect(store.list_executions(error_step: "ship").map(&:id)).to contain_exactly(shipped.id)
      expect(store.count_executions(group_by: :status, error_class: "Timeout::Error")).to eq("running" => 2)
      expect(store.list_executions(error_class: "Timeout::Error", status: "failed")).to be_empty
    end

    it "bounds the failed attempt's started_at by error_from (inclusive) and error_to (exclusive)" do
      older = query_execution(created_at: hour - days(1))
      query_attempt(older, status: "failed", error_class: "Timeout::Error", started_at: hour + hours(1))
      early = query_execution
      query_attempt(early, status: "failed", error_class: "Timeout::Error", started_at: hour - minutes(1))
      query_attempt(early, attempt: 2, started_at: hour + hours(1))
      at_to = query_execution
      query_attempt(at_to, status: "failed", error_class: "Timeout::Error", started_at: hour + hours(2))

      window = {error_class: "Timeout::Error", error_step: "charge", error_from: hour, error_to: hour + hours(2)}
      expect(store.list_executions(**window).map(&:id)).to contain_exactly(older.id)
      expect(store.count_executions(group_by: :status, **window)).to eq("running" => 1)
      expect(store.list_executions(error_from: hour).map(&:id)).to contain_exactly(older.id, at_to.id)
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
    it "counts starts by started_at and terminal statuses by finished_at in aligned buckets" do
      query_execution(created_at: hour + minutes(5))
      query_execution(created_at: hour + minutes(10), status: "completed", finished_at: hour + minutes(20))
      query_execution(created_at: hour - hours(1), status: "failed", finished_at: hour + minutes(70))
      query_execution(created_at: hour - hours(1), status: "compensated", finished_at: hour - minutes(1))
      query_execution(created_at: hour + minutes(15), status: "compensating")

      series = store.execution_series(from: hour + minutes(10), to: hour + hours(2), bucket: hours(1))

      expect(series[:truncated]).to be(false)
      expect(series[:rows].map(&:first)).to eq([hour, hour + hours(1)])
      expect(series[:rows].map(&:last)).to eq([
        {"started" => 2, "completed" => 1, "compensated" => 0, "failed" => 0, "compensation_failed" => 0},
        {"started" => 0, "completed" => 0, "compensated" => 0, "failed" => 1, "compensation_failed" => 0}
      ])
    end

    it "keeps empty buckets and filters by saga" do
      query_execution(created_at: hour + minutes(1))
      query_execution(saga_name: invoice, created_at: hour + minutes(2))

      series = store.execution_series(from: hour, to: hour + minutes(30), bucket: 600, saga_name: invoice)

      expect(series[:rows].map(&:first)).to eq([hour, hour + minutes(10), hour + minutes(20)])
      expect(series[:rows].map { |_, counts| counts["started"] }).to eq([1, 0, 0])
    end

    it "counts at most max_rows timestamps of each kind, newest first" do
      [1, 2, 61].each { |minute| query_execution(created_at: hour + minutes(minute)) }

      series = store.execution_series(from: hour, to: hour + hours(2), bucket: hours(1), max_rows: 2)

      expect(series[:truncated]).to be(true)
      expect(series[:rows].map { |_, counts| counts["started"] }).to eq([1, 1])
    end

    it "rejects empty or too many buckets" do
      expect { store.execution_series(from: hour, to: hour + hours(1), bucket: 0) }.to raise_error(ArgumentError)
      expect { store.execution_series(from: hour, to: hour + days(1), bucket: 1) }.to raise_error(ArgumentError)
    end
  end

  describe "#step_latency" do
    it "computes nearest-rank percentiles per saga, step and direction" do
      execution = query_execution
      (1..20).each { |attempt| query_attempt(execution, attempt: attempt, duration_ms: attempt * 10.0) }
      query_attempt(execution, step_name: "reserve", direction: "compensate", status: "failed", duration_ms: 40.0)
      query_attempt(query_execution(saga_name: invoice), step_name: "render", duration_ms: 5.0)

      latency = store.step_latency(from: hour, to: hour + hours(1))

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
      query_attempt(execution, attempt: 4, started_at: hour - 1, duration_ms: 500.0)
      query_attempt(execution, attempt: 5, started_at: hour + hours(1), duration_ms: 500.0)
      query_attempt(query_execution(saga_name: invoice), step_name: "render", duration_ms: 5.0)

      rows = store.step_latency(from: hour, to: hour + hours(1), saga_name: checkout)[:rows]

      expect(rows).to contain_exactly(include(step_name: "charge", count: 1, max: 10.0))
    end

    it "uses at most max_rows of the newest attempts" do
      execution = query_execution
      [10.0, 20.0, 30.0].each_with_index do |duration, index|
        query_attempt(execution, attempt: index + 1, started_at: hour + minutes(index), duration_ms: duration)
      end

      latency = store.step_latency(from: hour, to: hour + hours(1), max_rows: 2)

      expect(latency[:truncated]).to be(true)
      expect(latency[:rows]).to contain_exactly(include(count: 2, p50: 20.0, max: 30.0))
    end
  end

  describe "#failure_summary" do
    it "groups failed attempts by error class, saga and step, most frequent first" do
      first = query_execution
      second = query_execution
      query_attempt(first, attempt: 1, status: "failed", started_at: hour + minutes(1),
        error_class: "Timeout::Error", error_message: "first timeout")
      query_attempt(second, attempt: 1, status: "failed", started_at: hour + minutes(3),
        error_class: "Timeout::Error", error_message: "latest timeout")
      query_attempt(first, attempt: 2, status: "failed", started_at: hour + minutes(2),
        error_class: "ArgumentError", error_message: "bad amount")
      query_attempt(first, step_name: "ship", status: "failed", started_at: hour + minutes(4),
        error_class: "Timeout::Error", error_message: "ship timeout")
      query_attempt(first, attempt: 3, started_at: hour + minutes(5))

      summary = store.failure_summary(from: hour, to: hour + hours(1))

      expect(summary.first).to include(
        error_class: "Timeout::Error", saga_name: checkout, step_name: "charge", count: 2, execution_count: 2,
        sample_message: "latest timeout", sample_execution_id: second.id
      )
      expect(summary.first[:last_seen_at]).to be_within(0.01).of(hour + minutes(3) + 0.1)
      expect(summary.drop(1).map { |group| group.values_at(:error_class, :step_name, :count) })
        .to eq([["Timeout::Error", "ship", 1], ["ArgumentError", "charge", 1]])
    end

    it "filters by window and saga and caps the groups at limit" do
      execution = query_execution
      query_attempt(execution, attempt: 1, status: "failed", started_at: hour - minutes(1), error_class: "OldError")
      query_attempt(execution, attempt: 2, status: "failed", error_class: "KeyError")
      query_attempt(execution, step_name: "ship", status: "failed", started_at: hour + minutes(1), error_class: "IOError")
      query_attempt(query_execution(saga_name: invoice), step_name: "render", status: "failed", error_class: "KeyError")

      expect(store.failure_summary(from: hour, to: hour + hours(1), saga_name: checkout).map { |group| group[:error_class] })
        .to eq(%w[IOError KeyError])
      expect(store.failure_summary(from: hour, to: hour + hours(1), limit: 1).size).to eq(1)
    end

    it "counts the distinct executions of a group" do
      execution = query_execution
      query_attempt(execution, attempt: 1, status: "failed", error_class: "Timeout::Error")
      query_attempt(execution, attempt: 2, status: "failed", error_class: "Timeout::Error")

      expect(store.failure_summary(from: hour, to: hour + hours(1))).to contain_exactly(include(count: 2, execution_count: 1))
    end

    it "is empty without failures" do
      query_attempt(query_execution)

      expect(store.failure_summary(from: hour, to: hour + hours(1))).to eq([])
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
