# frozen_string_literal: true

require "rack/test"
require "lepus/saga/web"

RSpec.describe Lepus::Saga::Web do
  include Rack::Test::Methods

  let(:config) { Lepus::Saga::Web::Configuration.new }
  let(:app) { described_class.build(config) }
  let(:store) { Lepus::Saga.store }
  let(:json_headers) { {"CONTENT_TYPE" => "application/json", "HTTP_X_LEPUS_SAGA" => "1", "HTTP_ORIGIN" => "http://example.org"} }

  before do
    stub_const("WebSpecCheckout", Class.new(Lepus::Saga::Definition) do
      saga_name "orders.checkout"
      partition "billing"

      step :reserve, compensate: :release
      step :charge, retry: {attempts: 4}
      step :ship

      def reserve = nil

      def release = nil

      def charge = nil

      def ship = nil
    end)
  end

  def create_execution(status: "running", current_step: "reserve", resource_id: "order-1", created_at: Time.now.utc, progress_at: created_at)
    execution = store.create_execution(
      saga_name: "orders.checkout", resource_type: "Order", resource_id: resource_id,
      current_step: current_step, started_at: created_at, last_progress_at: progress_at
    )
    store.update_execution(execution, status: status, created_at: created_at,
      finished_at: (created_at if Lepus::Saga::ExecutionBehaviour::TERMINAL_STATUSES.include?(status)))
  end

  def fail_attempt(execution, step_name, error_class, attempt: 1, at: Time.now.utc)
    record = store.create_step_attempt(execution, step_name: step_name, direction: "execute", epoch: 0, attempt: attempt, started_at: at)
    store.update_step_attempt(record, status: "failed", finished_at: at, error_class: error_class, error_message: "boom")
  end

  def json = JSON.parse(last_response.body)

  def post_json(path, body = {}, headers = json_headers)
    post(path, JSON.generate(body), headers)
  end

  describe "GET /api/me" do
    it "reports the allowed actions and the poll settings" do
      config.default_poll_interval = 15
      config.title = "Order sagas"

      get "/api/me"

      expect(last_response.status).to eq(200)
      expect(json).to include(
        "title" => "Order sagas", "read_only" => false, "queries" => true, "poll_interval" => 15,
        "poll_intervals" => [0, 2, 5, 15, 60], "stalled_after" => 900, "actions" => {"retry" => true, "compensate" => true}
      )
    end
  end

  describe "GET /api/sagas" do
    it "lists definitions with in-progress and stopped counts per step" do
      create_execution(current_step: "charge")
      create_execution(current_step: "charge")
      create_execution(status: "failed", current_step: "ship")
      create_execution(status: "completed", current_step: "ship")

      get "/api/sagas"

      saga = json["sagas"].find { |item| item["name"] == "orders.checkout" }
      expect(saga).to include("known" => true, "partition" => "billing")
      expect(saga["steps"]).to eq([
        {"name" => "reserve", "compensate" => "release", "attempts" => 3},
        {"name" => "charge", "compensate" => nil, "attempts" => 4},
        {"name" => "ship", "compensate" => nil, "attempts" => 3}
      ])
      expect(saga["stations"]["charge"]).to include("running" => 2)
      expect(saga["stations"]["ship"]).to include("failed" => 1)
      expect(saga["totals"]).to eq("running" => 2, "failed" => 1, "completed" => 1)
    end

    it "counts the stalled executions of each step by status" do
      config.stalled_after = 600
      create_execution(current_step: "charge")
      create_execution(current_step: "charge", progress_at: ago(minutes(11)))
      create_execution(status: "compensating", current_step: "reserve", progress_at: ago(hours(1)))

      get "/api/sagas"

      stations = json["sagas"].find { |item| item["name"] == "orders.checkout" }["stations"]
      expect(json["stalled_after"]).to eq(600)
      expect(stations["charge"]).to include("running" => 2, "stalled" => {"running" => 1})
      expect(stations["reserve"]).to include("compensating" => 1, "stalled" => {"compensating" => 1})
    end
  end

  describe "GET /api/executions" do
    it "filters by saga, status, step and resource" do
      running = create_execution(current_step: "charge", resource_id: "order-77")
      create_execution(status: "failed", resource_id: "order-78")

      get "/api/executions", saga: "orders.checkout", status: "running,compensating", step: "charge", resource: "77"

      expect(json["executions"].map { |row| row["id"] }).to eq([running.id])
      expect(json["executions"].first).to include("partition" => "billing", "status" => "running", "current_step" => "charge")
      expect(json["next"]).to be_nil
    end

    it "filters by the error class and step of a failed attempt" do
      gateway = create_execution(current_step: "ship")
      fail_attempt(gateway, "charge", "GatewayTimeout")
      declined = create_execution(status: "failed", current_step: "charge")
      fail_attempt(declined, "charge", "CardDeclined")
      fail_attempt(create_execution, "ship", "GatewayTimeout")

      get "/api/executions", error: "GatewayTimeout", error_step: "charge"
      expect(json["executions"].map { |row| row["id"] }).to eq([gateway.id])

      get "/api/executions", error: "GatewayTimeout,CardDeclined", error_step: "charge"
      expect(json["executions"].map { |row| row["id"] }).to contain_exactly(gateway.id, declined.id)
    end

    it "bounds when the attempt failed with error_from and error_to" do
      retried = create_execution(created_at: ago(days(2)))
      fail_attempt(retried, "charge", "GatewayTimeout", at: ago(hours(1)))
      fail_attempt(create_execution(created_at: ago(days(3))), "charge", "GatewayTimeout", at: ago(days(3)))

      get "/api/executions", error: "GatewayTimeout", error_step: "charge", error_from: ago(days(1)).iso8601
      expect(json["executions"].map { |row| row["id"] }).to eq([retried.id])
    end

    it "lists stalled executions with stalled=1" do
      stalled = create_execution(progress_at: ago(minutes(20)))
      create_execution
      create_execution(status: "failed", progress_at: ago(hours(1)))

      get "/api/executions", stalled: "1"
      expect(json["executions"].map { |row| row["id"] }).to eq([stalled.id])

      get "/api/executions", stalled: "1", status: "failed"
      expect(last_response.status).to eq(400)
      expect(json["error"]).to eq("Stalled executions are running or compensating")
    end

    it "pages by started_at, latest first, after the last row shown" do
      ids = [2, 3, 1].map { |hour| create_execution(created_at: ago(hours(hour))).id }

      get "/api/executions", limit: 2
      first = json
      get "/api/executions", limit: 2, after: first["next"]

      expect(first).to include("sort" => "started_at", "dir" => "desc", "next" => ids[0])
      expect(first["executions"].map { |row| row["id"] }).to eq([ids[2], ids[0]])
      expect(json["executions"].map { |row| row["id"] }).to eq([ids[1]])
      expect(json["next"]).to be_nil
    end

    it "sorts by started_at or duration in either direction" do
      slow = create_execution(status: "completed", created_at: ago(hours(3)))
      store.update_execution(slow, duration_ms: 90_000)
      fast = create_execution(status: "completed", created_at: ago(hours(2)))
      store.update_execution(fast, duration_ms: 1_200)
      running = create_execution(created_at: ago(hours(1)))

      get "/api/executions", sort: "started_at", dir: "asc"
      expect(json["executions"].map { |row| row["id"] }).to eq([slow.id, fast.id, running.id])

      get "/api/executions", sort: "duration"
      expect(json["executions"].map { |row| row["id"] }).to eq([slow.id, fast.id, running.id])
      expect(json["executions"].map { |row| row["duration_ms"] }).to eq([90_000, 1_200, nil])

      get "/api/executions", sort: "duration", dir: "asc", limit: 1, after: fast.id
      expect(json["executions"].map { |row| row["id"] }).to eq([slow.id])
      expect(json["next"]).to eq(slow.id)
    end

    it "rejects unknown sorts" do
      get "/api/executions", sort: "resource_id"
      expect(last_response.status).to eq(400)
      expect(json["error"]).to eq("sort must be one of started_at, duration")

      get "/api/executions", dir: "up"
      expect(last_response.status).to eq(400)
    end

    it "filters by started_at" do
      create_execution(created_at: ago(days(2)))
      recent = create_execution(created_at: ago(hours(1)))

      get "/api/executions", from: ago(days(1)).iso8601

      expect(json["executions"].map { |row| row["id"] }).to eq([recent.id])
    end

    it "rejects malformed parameters" do
      get "/api/executions", from: "yesterday"
      expect(last_response.status).to eq(400)
      expect(json["error"]).to include("from")

      get "/api/executions", limit: "1000"
      expect(last_response.status).to eq(400)
    end
  end

  describe "GET /api/moving" do
    it "lists the executions moving at the busiest steps, leaving out stalled ones" do
      charging = Array.new(3) { create_execution(current_step: "charge") }
      shipping = create_execution(current_step: "ship")
      create_execution(current_step: "ship", progress_at: ago(hours(1)))
      create_execution(status: "failed", current_step: "reserve")

      get "/api/moving", per_station: 2

      expect(json).to include("stalled_after" => 900, "omitted" => 0, "now" => be_a(String))
      expect(json["stations"].map { |station| station.values_at("saga_name", "step_name", "count") })
        .to eq([["orders.checkout", "charge", 3], ["orders.checkout", "ship", 1]])
      expect(json["stations"].first["executions"].map { |row| row["id"] }).to eq(charging.last(2).reverse.map(&:id))
      expect(json["stations"].last["executions"].map { |row| row["id"] }).to eq([shipping.id])
    end

    it "caps the number of steps" do
      create_execution(current_step: "charge")
      create_execution(current_step: "ship")

      get "/api/moving", stations: 1

      expect(json["stations"].size).to eq(1)
      expect(json["omitted"]).to eq(1)
    end
  end

  describe "GET /api/recent" do
    def finish(execution, status, at:, attempts: [])
      attempts.each_with_index do |(step, direction, attempt_status), index|
        record = store.create_step_attempt(execution, step_name: step, direction: direction, epoch: 0, attempt: index + 1, started_at: at - 1)
        store.update_step_attempt(record, status: attempt_status, finished_at: at)
      end
      direction = (attempts.any? { |_step, attempt_direction, _| attempt_direction == "compensate" }) ? "compensate" : "execute"
      current = attempts.last&.first || "reserve"
      store.update_execution(execution, status: status, direction: direction, current_step: current, finished_at: at, duration_ms: 1_000)
    end

    it "lists the executions that finished since the given time per saga, with the steps they passed" do
      since = ago(minutes(1))
      completed = finish(create_execution(created_at: ago(minutes(2))), "completed", at: ago(30),
        attempts: [%w[reserve execute succeeded], %w[charge execute succeeded], %w[ship execute succeeded]])
      failed = finish(create_execution(created_at: ago(40)), "failed", at: ago(20), attempts: [%w[reserve execute failed]])
      compensated = finish(create_execution(created_at: ago(40)), "compensated", at: ago(10),
        attempts: [%w[reserve execute succeeded], %w[charge execute failed], %w[reserve compensate succeeded]])
      finish(create_execution(created_at: ago(hours(1))), "completed", at: ago(minutes(5)))
      create_execution

      get "/api/recent", since: since.iso8601(3)

      expect(json).to include("since" => since.utc.iso8601(3), "now" => be_a(String))
      line = sole(json["lines"])
      expect(line).to include("saga_name" => "orders.checkout", "total" => 3, "counts" => {"completed" => 1, "failed" => 1, "compensated" => 1})
      expect(line["executions"].map { |row| row.values_at("id", "status", "reached", "back_to") }).to eq([
        [compensated.id, "compensated", "charge", "reserve"],
        [failed.id, "failed", "reserve", nil],
        [completed.id, "completed", "ship", nil]
      ])
      expect(line["executions"].first).to include("started_at", "finished_at", "duration_ms" => 1_000)
    end

    it "keeps per_saga executions of each line and counts the rest" do
      3.times { |index| finish(create_execution, "completed", at: ago(index + 1)) }

      get "/api/recent", since: ago(minutes(1)).iso8601, per_saga: 2

      expect(sole(json["lines"])).to include("total" => 3, "counts" => {"completed" => 3})
      expect(sole(json["lines"])["executions"].size).to eq(2)
    end

    it "lists, without counting, the ones that finished from replay_from" do
      since = ago(minutes(1))
      early = finish(create_execution, "completed", at: since - 1)
      late = finish(create_execution, "completed", at: ago(10))
      finish(create_execution, "completed", at: since - 5)

      get "/api/recent", since: since.iso8601(3), replay_from: (since - 2).iso8601(3)

      line = sole(json["lines"])
      expect(line).to include("total" => 1, "counts" => {"completed" => 1})
      expect(line["executions"].map { |row| row["id"] }).to eq([late.id, early.id])
    end

    it "needs a since before now" do
      get "/api/recent"
      expect(last_response.status).to eq(400)

      get "/api/recent", since: (Time.now.utc + 60).iso8601
      expect(last_response.status).to eq(400)
    end
  end

  describe "GET /api/executions/:id" do
    it "returns the execution with its context, attempts and other runs of the resource" do
      execution = create_execution
      other = create_execution
      store.create_step_attempt(execution, step_name: "reserve", direction: "execute", epoch: 0, attempt: 1, started_at: Time.now.utc)

      get "/api/executions/#{execution.id}"

      expect(json["execution"]).to include("id" => execution.id, "context" => {})
      expect(json["definition"]["steps"].map { |step| step["name"] }).to eq(%w[reserve charge ship])
      expect(json["attempts"].map { |attempt| attempt["step_name"] }).to eq(["reserve"])
      expect(json["related"].map { |run| run["id"] }).to eq([other.id])
    end

    it "answers 404 for an unknown id" do
      get "/api/executions/missing"

      expect(last_response.status).to eq(404)
    end
  end

  describe "insight endpoints" do
    let(:execution) { create_execution(status: "failed", created_at: ago(minutes(30))) }

    before do
      attempt = store.create_step_attempt(execution, step_name: "charge", direction: "execute", epoch: 0, attempt: 1, started_at: ago(minutes(20)))
      store.update_step_attempt(attempt, status: "failed", finished_at: ago(minutes(19)), duration_ms: 60_000.0,
        error_class: "Timeout::Error", error_message: "gateway timeout")
    end

    it "serves the throughput series in buckets" do
      get "/api/series", from: ago(hours(1)).iso8601, to: Time.now.utc.iso8601

      expect(json["bucket"]).to eq(60)
      expect(json["rows"].sum { |row| row["started"] }).to eq(1)
      expect(json["rows"].sum { |row| row["failed"] }).to eq(1)
      expect(json["truncated"]).to be(false)
    end

    it "serves failures grouped by error, latency percentiles and stalled executions" do
      get "/api/insights/failures"
      expect(json["failures"]).to contain_exactly(include("error_class" => "Timeout::Error", "count" => 1, "execution_count" => 1, "sample_execution_id" => execution.id))

      get "/api/insights/latency"
      expect(json["rows"]).to contain_exactly(include("step_name" => "charge", "p50" => 60_000.0))

      stalled = create_execution(created_at: ago(hours(2)))
      get "/api/stalled", minutes: 30
      expect(json).to include("stalled_after" => 1800)
      expect(json["executions"].map { |row| row["id"] }).to eq([stalled.id])

      config.stalled_after = 3 * 3600
      get "/api/stalled"
      expect(json["executions"]).to be_empty
    end
  end

  describe "POST /api/executions/:id/retry" do
    it "retries a failed execution" do
      execution = create_execution(status: "failed", current_step: "charge")

      post_json "/api/executions/#{execution.id}/retry"

      expect(last_response.status).to eq(200)
      expect(json["execution"]).to include("status" => "running", "epoch" => 1)
      expect(saga_exchange.messages.size).to eq(1)
    end

    it "answers 409 when the execution cannot be retried" do
      execution = create_execution(status: "completed")

      post_json "/api/executions/#{execution.id}/retry"

      expect(last_response.status).to eq(409)
      expect(json["error"]).to eq("Cannot retry execution in status completed")
    end

    it "answers 404 for an unknown execution" do
      post_json "/api/executions/missing/retry"

      expect(last_response.status).to eq(404)
    end

    it "answers 409 without touching the execution when its saga is not loaded" do
      execution = store.create_execution(saga_name: "invoices.issue", resource_type: "Invoice", resource_id: "inv-1", current_step: "issue")
      store.update_execution(execution, status: "failed")

      %w[retry compensate].each do |action|
        post_json "/api/executions/#{execution.id}/#{action}"

        expect(last_response.status).to eq(409)
        expect(json["error"]).to eq("Saga invoices.issue is not loaded in this process")
      end
      expect(store.find_execution(execution.id)).to have_attributes(status: "failed", epoch: 0)
      expect(saga_exchange.messages).to be_empty
    end
  end

  describe "POST /api/executions/:id/compensate" do
    it "compensates with the given reason" do
      execution = create_execution(current_step: "charge")
      store.finish_step_attempt(
        store.create_step_attempt(execution, step_name: "reserve", direction: "execute", epoch: 0, attempt: 1, started_at: Time.now.utc),
        "succeeded"
      )

      post_json "/api/executions/#{execution.id}/compensate", {reason: "customer cancelled"}

      expect(json["execution"]).to include("status" => "compensating", "current_step" => "reserve", "failure_reason" => "customer cancelled")
    end
  end

  describe "cross-site protection" do
    let(:execution) { create_execution(status: "failed") }

    it "accepts a same-origin Referer when the browser sends no Origin" do
      post_json "/api/executions/#{execution.id}/retry", {}, json_headers.except("HTTP_ORIGIN").merge("HTTP_REFERER" => "http://example.org/sagas/")

      expect(last_response.status).to eq(200)
    end

    {
      "without the custom header" => {"HTTP_X_LEPUS_SAGA" => nil},
      "without a JSON content type" => {"CONTENT_TYPE" => "application/x-www-form-urlencoded"},
      "from a foreign origin" => {"HTTP_ORIGIN" => "https://evil.example"},
      "from a foreign referer" => {"HTTP_ORIGIN" => nil, "HTTP_REFERER" => "https://evil.example/page"},
      "without an origin or referer" => {"HTTP_ORIGIN" => nil}
    }.each do |description, overrides|
      it "rejects a request #{description}" do
        post_json "/api/executions/#{execution.id}/retry", {}, json_headers.merge(overrides).compact

        expect(last_response.status).to eq(403)
        expect(json["error"]).to eq("Cross-site request rejected")
        expect(store.find_execution(execution.id).status).to eq("failed")
      end
    end
  end

  describe "authorization" do
    it "refuses every request the hook does not allow to read" do
      config.authorize = ->(_env, action) { action != :read }

      get "/api/me"
      expect(last_response.status).to eq(403)
      expect(json["error"]).to eq("Forbidden")

      get "/"
      expect(last_response.status).to eq(403)
    end

    it "refuses an action the hook denies and reports it in /api/me" do
      config.authorize = ->(env, action) { action != :retry || env["HTTP_X_ROLE"] == "admin" }
      execution = create_execution(status: "failed")

      get "/api/me"
      expect(json["actions"]).to eq("retry" => false, "compensate" => true)

      post_json "/api/executions/#{execution.id}/retry"
      expect(last_response.status).to eq(403)

      post_json "/api/executions/#{execution.id}/retry", {}, json_headers.merge("HTTP_X_ROLE" => "admin")
      expect(last_response.status).to eq(200)
    end

    it "refuses actions and hides them when read-only" do
      config.read_only = true
      execution = create_execution(status: "failed")

      get "/api/me"
      expect(json).to include("read_only" => true, "actions" => {"retry" => false, "compensate" => false})

      post_json "/api/executions/#{execution.id}/compensate"
      expect(last_response.status).to eq(403)
      expect(json["error"]).to eq("The console is read-only")
    end
  end

  describe "routing" do
    it "answers 404 for unknown paths and 405 for a wrong method" do
      get "/api/nothing"
      expect(last_response.status).to eq(404)
      expect(json["error"]).to eq("Not found")

      get "/api/executions/abc/retry"
      expect(last_response.status).to eq(405)

      post "/api/me"
      expect(last_response.status).to eq(405)

      get "/elsewhere"
      expect(last_response.status).to eq(404)
    end

    it "answers 501 when the store has no query methods" do
      allow(store).to receive(:list_executions).and_raise(NotImplementedError)

      get "/api/executions"

      expect(last_response.status).to eq(501)
    end
  end

  describe "the page" do
    it "points its base href at the mount path and escapes the title" do
      config.title = "Sagas <prod>"

      get "/", {}, "SCRIPT_NAME" => "/admin/sagas"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('<base href="/admin/sagas/">')
      expect(last_response.body).to include("<title>Sagas &lt;prod&gt;</title>")
      expect(last_response.body).to match(%r{href="assets-\h{16}/app\.css"})
      expect(last_response.headers["content-security-policy"]).to include("default-src 'self'", "script-src 'self'")
      expect(last_response.headers["x-content-type-options"]).to eq("nosniff")
    end

    it "serves the page from the root when mounted there" do
      get "/"

      expect(last_response.body).to include('<base href="/">')
    end

    it "works when mounted through Rack::Builder#map" do
      inner = app
      mounted = Rack::Builder.new { map("/ops/sagas") { run inner } }.to_app

      response = Rack::MockRequest.new(mounted).get("/ops/sagas/")

      expect(response.body).to include('<base href="/ops/sagas/">')
    end
  end

  describe "static assets" do
    let(:asset_path) { last_response.body[%r{assets-\h{16}/app\.css}] }

    before { get "/" }

    it "caches digested paths for a year and answers 304 to a matching ETag" do
      get "/#{asset_path}"

      expect(last_response.status).to eq(200)
      expect(last_response.headers["content-type"]).to eq("text/css")
      expect(last_response.headers["cache-control"]).to include("immutable")
      etag = last_response.headers["etag"]

      get "/#{asset_path}", {}, "HTTP_IF_NONE_MATCH" => etag
      expect(last_response.status).to eq(304)
      expect(last_response.body).to be_empty
    end

    it "revalidates plain asset paths and stale digests" do
      get "/assets/js/main.js"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["cache-control"]).to eq("no-cache")
      expect(last_response.headers["content-type"]).to include("javascript")

      get "/assets-0000000000000000/app.css"
      expect(last_response.headers["cache-control"]).to eq("no-cache")
    end

    it "serves the vendored fonts" do
      get "/assets/fonts/overpass/overpass-latin-wght.woff2"

      expect(last_response.status).to eq(200)
      expect(last_response.body.byteslice(0, 4)).to eq("wOF2")
    end

    it "serves the brand icons" do
      get "/assets/favicon.svg"
      expect(last_response.headers["content-type"]).to eq("image/svg+xml")

      get "/assets/apple-touch-icon.png"
      expect(last_response.headers["content-type"]).to eq("image/png")
    end

    it "never serves files outside the assets directory" do
      get "/assets/../index.html"
      expect(last_response.status).to eq(404)

      get "/assets/%2e%2e/%2e%2e/lib/lepus/saga.rb"
      expect(last_response.status).to eq(404)
    end
  end

  describe ".call" do
    after { described_class.reset! }

    it "builds the app from the global configuration" do
      described_class.configure { |web| web.title = "Global" }

      status, _headers, body = described_class.call(Rack::MockRequest.env_for("/api/me"))

      expect(status).to eq(200)
      expect(JSON.parse(body.each.to_a.join)["title"]).to eq("Global")
    end
  end
end
