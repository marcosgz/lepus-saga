<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/lockup-lepus-saga-on-dark.svg">
    <img alt="Lepus saga" src="docs/brand/lockup-lepus-saga-on-light.svg" width="359">
  </picture>
</h1>

Linear sagas on top of [Lepus](https://github.com/marcosgz/lepus).

A saga is an ordered list of steps with optional compensations and retry policies. State lives in a store: one execution per saga run and one step attempt per try of a step. Messages on the saga exchange only point at the next unit of work, so duplicate deliveries are fenced out, and lost messages are healed by re-publishing whatever the execution record says is current.

This gem is the engine and has no ORM dependency. Storage comes from an adapter:

| Store | Gem | `config.store =` |
| --- | --- | --- |
| ActiveRecord (PostgreSQL, MySQL/MariaDB, SQLite) | [lepus-saga-active_record](https://github.com/marcosgz/lepus-saga-active_record) | `:active_record` |
| In-process memory (tests, scripts) | this gem | `:memory` |

## Installation

lepus-saga runs on plain Ruby and does not depend on ActiveSupport. Like Lepus, it fits into Rails when ActiveSupport is there: durations such as `15.minutes` are accepted wherever seconds are, engine events reach `ActiveSupport::Notifications`, and the optional `Lepus::Saga::ResumeStuckJob` runs on ActiveJob.

```ruby
gem "lepus-saga"
gem "lepus-saga-active_record"
```

```bash
bundle install
bin/rails generate lepus:saga:install
bin/rails db:migrate
```

## Configuration

```ruby
# config/initializers/lepus_saga.rb
Lepus::Saga.configure do |config|
  config.store = :active_record                  # a name, a store class or a store instance
  config.exchange_name = "lepus.saga"            # topic exchange; queues are "<exchange>.execute[.<partition>]"
  config.max_resumes = 5                         # re-publishes of a stalled execution before it is abandoned
  config.backlog_threshold = 100                 # ready messages above which a partition counts as backlogged
  config.backlog_patience = 2 * 3600             # seconds stalled behind a backlog before one re-publish
  config.stale_running_attempt_after = 5 * 60    # seconds after which a running attempt is closed as abandoned
end
```

Durations are seconds. With ActiveSupport loaded, `2.hours` and other `ActiveSupport::Duration` values work as well.

Configure it before the consumer classes load, because `saga_partition` reads the exchange and queue names when the class body runs.

A store name is resolved the way Esse resolves plugins: `:active_record` requires `lepus/saga/stores/active_record` (shipped by the adapter gem) and instantiates `Lepus::Saga::Stores::ActiveRecord`. `Lepus::Saga.store` returns the configured instance and raises `Lepus::Saga::ConfigurationError` when there is none.

## Defining a saga

```ruby
class Orders::CheckoutSaga < Lepus::Saga::Definition
  saga_name "orders.checkout"
  partition "default"

  step :reserve_stock, compensate: :release_stock, retry: { attempts: 5 }
  step :persist_local

  def reserve_stock
    context["reservation_id"] = Inventory.reserve(resource)
  end

  def release_stock
    Inventory.release(context["reservation_id"])
  end

  def persist_local
    skip!("already persisted") if resource.persisted_remotely?
    resource.update!(reservation_id: context["reservation_id"])
  end
end

Orders::CheckoutSaga.start(resource: order, context: { "name" => order.name })
Orders::CheckoutSaga.start(resource: { type: "Order", id: "abc" }, partition: "priority")
```

Step methods run with `execution`, `context`, `resource` and `step_attempt`. Changes to `context` are saved when the step succeeds. Delivery is at-least-once, so steps must be idempotent. `resource` is `resource_type.constantize.find(resource_id)`; override `find_resource` for anything else.

Inside a step:

- `skip!(reason = nil)` records the step as skipped and continues.
- `complete!(reason = nil)` finishes the execution successfully right away.
- `fail!(reason)` fails without retrying and compensates the succeeded steps.
- Any other exception is retried up to the step's `retry:` attempts (default 3), then compensated.

Call `start` after the transaction that changed the resource has committed.

## Consumers

Declare one executor consumer per partition:

```ruby
class SagaExecutorConsumer < Lepus::Saga::ExecutorConsumer
  saga_partition "default", worker: { name: "saga", threads: 5 }, retry_delay: 10_000
end
```

Failed attempts are rejected into a TTL retry queue (`retry_delay` in milliseconds), and the error queue is enabled.

## Operations

```ruby
Lepus::Saga.retry(execution)                     # restart a failed/stuck execution from its current step
Lepus::Saga.compensate(execution, reason: "...") # force compensation of a non-terminal execution
Lepus::Saga.resume_stuck(older_than: 15 * 60, limit: 100, max_resumes: Lepus::Saga.config.max_resumes)
```

`retry` and `compensate` lock the execution, reload the record you pass in place and return it.

`resume_stuck` re-publishes executions whose cursor has not moved for `older_than` seconds. An execution re-published `max_resumes` times without progress is compensated, or failed when there is nothing to undo. While a partition's queue holds more than `backlog_threshold` ready messages, its executions are left alone and re-published once after `backlog_patience`.

Schedule it with the bundled ActiveJob (`require "lepus/saga/resume_stuck_job"`, needs `activejob`), e.g. in Solid Queue's `config/recurring.yml`:

```yaml
saga_resume_stuck:
  class: Lepus::Saga::ResumeStuckJob
  args: [15]
  schedule: every 5 minutes
```

Without ActiveJob, call it from any scheduler:

```ruby
class SagaResumeStuckWorker
  include Sidekiq::Job

  def perform = Lepus::Saga.resume_stuck(older_than: 15 * 60)
end
```

Reads go through the store too, so they work with any adapter:

```ruby
store = Lepus::Saga.store
store.find_execution(id)
store.executions_for_resource("Order", order.id) # newest first
store.step_attempts(execution)                       # chronological
```

Adapters usually offer richer queries on their own records (`Lepus::Saga::ActiveRecord::Execution.for_resource(...).completed`).

## Web console

`Lepus::Saga::Web` is a Rack app for the engineer on call. It has three screens:

- **Map**: every saga drawn as a line of its steps. Tokens are the executions moving right now, placed along the step by how long they have spent in it against the step's median, up to three lanes per step and a "+N running" pill for the rest (static when the viewer prefers reduced motion). Each step shows its stalled executions and its failures in the selected time range (1 h, 24 h or 7 d, kept in the URL). The headline reads as the key: how many executions are moving, compensating and stalled, and how many failed. Below the map, a full-width throughput chart (with a table view), **Needs attention** (failed attempts grouped by error, saga and step, each linking to exactly the executions that failed that way in the range) and **Waiting the longest** (the stalled executions with the oldest progress).
- **Executions**: a paged list filtered by status, saga, step, error, time range or stalled.
- **Execution**: a replay of the execution along its line, its attempt history with errors and backtraces, its context and other runs of the same resource. Retry and compensate are one click plus a confirmation.

It reads through the store's optional query methods, so the store must report `queries?` (`Stores::Memory` and `Stores::ActiveRecord` do).

```ruby
require "lepus/saga/web"
```

It has no authentication of its own: mount it behind yours. In Rails, with Devise:

```ruby
# config/routes.rb
authenticate :user, ->(user) { user.admin? } do
  mount Lepus::Saga::Web => "/workflows"
end
```

or with a route constraint:

```ruby
constraints(->(request) { request.env["warden"].user&.admin? }) do
  mount Lepus::Saga::Web => "/workflows"
end
```

In a plain `config.ru`:

```ruby
require "lepus/saga/web"

use Rack::Auth::Basic, "SAGA" do |user, password|
  Rack::Utils.secure_compare(user, ENV.fetch("LEPUS_SAGA_USER")) & Rack::Utils.secure_compare(password, ENV.fetch("LEPUS_SAGA_PASSWORD"))
end
run Lepus::Saga::Web
```

The console works under any mount path: the page's `<base href>` is the mount point and every URL in it is relative.

```ruby
Lepus::Saga::Web.configure do |config|
  config.authorize = ->(env, action) { action == :read || env["warden"].user&.admin? } # :read, :retry or :compensate
  config.read_only = false          # true hides retry and compensate and refuses them
  config.title = "SAGA"
  config.default_poll_interval = 5  # seconds: 0, 2, 5, 15 or 60
  config.max_rows = 50_000          # rows read for the throughput series and step latency
  config.stalled_after = 15 * 60    # seconds without progress before an in-progress execution counts as stalled
end
```

`authorize` runs on every request: a falsy answer for `:read` returns 403 for the whole console, and for `:retry` or `:compensate` it refuses that action and the page hides its button. Retry and compensate are POSTs that need a JSON body, an `X-Lepus-Saga` header and a same-origin `Origin` (or `Referer`), so a cookie-authenticated session cannot be driven from another site.

The page refreshes itself by polling the JSON API. The Live button in the top bar picks the interval: Paused, 2, 5, 15 or 60 seconds (`default_poll_interval` until the viewer picks one). Polling also pauses while the tab is hidden, and the map's tokens freeze while paused. The theme follows the system, or Light or Dark when picked; the interval, the theme and the time range are kept in the browser.

Content Security Policy: the console loads only its own files (no inline scripts or styles, no `eval`, no CDN) and sends `default-src 'self'` with its page. A host-wide policy works as long as it allows `'self'` for scripts, styles, fonts and fetches, and `data:` images. Static files are served with ETags; the page references them under a digest path, cached for a year.

To see the console without a database or RabbitMQ, run `bin/web-demo` from a checkout: it seeds an in-memory store with a week of executions generated by the real engine, keeps starting new ones, and serves the console on http://127.0.0.1:9292 (`PORT`, `HOST` and `DAYS` change it). `HEAVY=1` adds the load of a bad day: thousands of failed attempts, hundreds of executions crowding one step and hundreds of stalled ones. It is not part of the gem.

The font is Overpass, under the SIL Open Font License (`web/assets/fonts/overpass/OFL.txt`).

## Instrumentation and logging

Events go through `Lepus.instrument`, which publishes them to `ActiveSupport::Notifications` when it is loaded and does nothing otherwise. They are suffixed with `.lepus`: `saga.started`, `saga.step.started`, `saga.step.finished`, `saga.step.failed`, `saga.step.skipped`, `saga.completed`, `saga.compensation_started`, `saga.compensated`, `saga.failed`, `saga.compensation_failed`, `saga.resumed`. The payload carries the execution record under `:execution`.

```ruby
ActiveSupport::Notifications.subscribe(/\Asaga\./) do |name, _started, _finished, _id, payload|
  Lepus::Saga::LogSubscriber.call(name.delete_suffix(".lepus"), payload)
end
```

`LogSubscriber` writes one `key=value` line per event to `Lepus.logger`, at debug for step progress, warn for step failures and error for failed sagas.

## Testing

```ruby
require "lepus/saga/testing"

Lepus::Testing.enable!
Orders::CheckoutSaga.start(resource: order)
Lepus::Saga::Testing.drain(consumer: SagaExecutorConsumer)
```

`drain` delivers the fake saga exchange's messages to the consumer until it is empty, redelivering rejected messages right away so retries run inline. It raises `Lepus::Saga::Testing::DrainStallError` after `max_iterations` (default 50).

Tests that should not touch a database can run on the memory store: `Lepus::Saga.config.store = :memory`, and `Lepus::Saga.store.clear!` between examples.

## Architecture

```
Definition.start ──> store.create_execution ──> StepProducer ──> saga exchange
                                                                       │
ExecutorConsumer <─────────────────────────────────────────────────────┘
      │
      └─> Executor
            prepare:  store.with_locked_execution (fence epoch/step/direction, close
                      abandoned attempts, count them, store.create_step_attempt)
            run step: no lock held (user code may be slow)
            finish:   store.with_locked_execution (finish the attempt, move the cursor)
```

- `Definition`, `Executor`, `ExecutorConsumer`, `StepProducer`, `QueueDepth`, `Instrumentation`, `LogSubscriber` and `Testing` only talk to `Lepus::Saga.store`.
- `Lepus::Saga::Stores::Base` is the persistence contract. Every method is documented in [`lib/lepus/saga/stores/base.rb`](lib/lepus/saga/stores/base.rb).
- `Lepus::Saga::ExecutionBehaviour` and `Lepus::Saga::StepAttemptBehaviour` hold what records mean: statuses and predicates (`running?`, `terminal?`, `compensate_direction?`), `record_progress`, `definition_class`, `partition`, `current_step_scope`, `duration` and `finish_attributes`. Adapters include them into their own record classes.

### The store contract

| Method | Semantics |
| --- | --- |
| `create_execution(attributes)` | Inserts an execution with a UUIDv7 id; defaults status `running`, direction `execute`, epoch and resume_count 0, context `{}` |
| `find_execution(id)` | The record or nil, never locked |
| `save_execution(execution)` | Persists the record's attributes, returns it |
| `with_lock(execution) { }` | Exclusive row lock for the block after reloading the record in place; writes kept on return (including `next`), discarded on raise; returns the block value |
| `with_locked_execution(id) { \|execution_or_nil\| }` | Same, from an id; Base implements it with `find_execution` + `with_lock`, adapters may do it in one query |
| `increment_resume_count(execution)` | One atomic `resume_count = resume_count + 1` that touches updated_at; sets and returns the stored value |
| `stalled_executions(before:)` | Running or compensating executions with `last_progress_at < before`, oldest first, as an Enumerable the caller may stop early |
| `executions_for_resource(type, id)` | A resource's executions, newest first |
| `create_step_attempt(execution, attributes)` | Inserts a `running` attempt; a second one with the same execution, step, direction, epoch and attempt raises `Lepus::Saga::DuplicateAttemptError` |
| `save_step_attempt(attempt)` | Persists the attempt, returns it |
| `step_attempts(execution)` | Attempts ordered by started_at, created_at |
| `count_step_attempts(execution, step_name:, direction:, epoch:)` | Attempts for that step, any status |
| `running_step_attempt?(execution, step_name:, direction:, epoch:, started_since:)` | A `running` attempt started at or after the cutoff exists |
| `stale_step_attempts(execution, step_name:, direction:, epoch:, started_before:)` | `running` attempts started before the cutoff |
| `step_succeeded?(execution, step_name)` | A `succeeded` attempt in the execute direction exists, any epoch |

Base builds `update_execution`, `update_step_attempt` and `finish_step_attempt` on top of these.

The query methods are optional. The engine never calls them; read-only tools such as dashboards do, after checking `queries?`. Base raises `NotImplementedError` from each and returns false from `queries?`.

| Method | Semantics |
| --- | --- |
| `queries?` | Whether the store implements the methods below |
| `list_executions(saga_name:, status:, current_step:, partition:, resource:, from:, to:, progress_from:, progress_to:, error_class:, error_step:, error_from:, error_to:, before_id:, limit: 50)` | Executions newest first by id, `limit` of them, the page after `before_id` when given. Every filter is optional: `saga_name`, `status` and `current_step` take a value or a list, `partition` matches the column or (when it is nil) the definition's partition, `resource` is a case-insensitive substring of resource_type or resource_id, `from`/`to` bound created_at and `progress_from`/`progress_to` bound last_progress_at (inclusive/exclusive), `error_class` and `error_step` (a value or a list) keep executions with a failed attempt of that error class at that step, started between `error_from` and `error_to` when given |
| `count_executions(group_by:, **filters)` | A Hash of counts keyed by `:saga_name`, `:status`, `:partition` or `:current_step`, or by arrays of values for an array such as `[:saga_name, :status]`; partition groups resolve nil to the definition's partition |
| `execution_series(from:, to:, bucket:, saga_name: nil, max_rows:)` | `{rows: [[bucket_start, {"started" => n, "completed" => n, "compensated" => n, "failed" => n, "compensation_failed" => n}], ...], truncated:}`: starts by created_at, terminal statuses by finished_at, every bucket of the window aligned to multiples of `bucket` seconds, at most `max_rows` timestamps of each kind (the newest) |
| `step_latency(from:, to:, saga_name: nil, max_rows:)` | `{rows: [{saga_name:, step_name:, direction:, count:, p50:, p95:, p99:, max:}, ...], truncated:}`: nearest-rank percentiles in milliseconds of succeeded and failed attempts started in the window, from the newest `max_rows` |
| `failure_summary(from:, to:, saga_name: nil, limit: 20)` | `[{error_class:, saga_name:, step_name:, count:, execution_count:, last_seen_at:, sample_message:, sample_execution_id:}, ...]`: failed attempts started in the window grouped by error class, saga and step, most frequent first, `execution_count` being the distinct executions and the sample the latest failure |
| `saga_names` | The distinct saga names in storage, sorted |

`max_rows` defaults to `Stores::Base::QUERY_MAX_ROWS` (50,000), and a series may hold at most 1,000 buckets. Stores compute buckets and percentiles in Ruby with the helpers Base provides, so they need nothing beyond filters, grouping and counting from their backend.

The engine changes an execution only inside `with_lock`/`with_locked_execution`. The two writes made without the lock are the atomic `increment_resume_count` and closing an attempt the worker opened itself. A store therefore needs a real exclusive lock (`SELECT ... FOR UPDATE` or an equivalent), atomic increments and a unique index on attempts. It does not need optimistic locking.

### Writing an adapter

1. Create a gem named `lepus-saga-<name>` with `lib/lepus/saga/stores/<name>.rb` defining `Lepus::Saga::Stores::<Name> < Lepus::Saga::Stores::Base`, so `config.store = :<name>` finds it.
2. Give it record classes that include `Lepus::Saga::ExecutionBehaviour` and `Lepus::Saga::StepAttemptBehaviour`. They need readers and writers for each behaviour's `ATTRIBUTES`, and `[](name)` returning the raw stored value. The behaviour's `partition` (the column, or the definition's partition when it is nil) must win over the column reader. ActiveRecord defines column readers in a generated module, so including the behaviour in the class body is enough; check that your ORM does the same.
3. Implement every method of `Stores::Base` that raises `NotImplementedError`.
4. Run the shared examples:

```ruby
# spec/lepus/saga/stores/sequel_spec.rb
require "lepus/saga/rspec"

RSpec.describe Lepus::Saga::Stores::Sequel do
  let(:store) { described_class.new }

  after { DB[:saga_step_attempts].delete && DB[:saga_executions].delete }

  it_behaves_like "a lepus saga store"   # every store method, including locks across threads
  it_behaves_like "a lepus saga engine"  # the executor, retry, compensate and resume_stuck end to end
end
```

Both accept `concurrency: false` to skip the threaded examples on a backend that cannot share data between threads.

5. Optionally implement the query methods, return true from `queries?` and add `it_behaves_like "a lepus saga query store"`. An adapter without them keeps working with the engine; tools that need them check `queries?` first.

A Sequel store would start like this (a sketch, not a shipped gem):

```ruby
require "lepus/saga"
require "sequel"

module Lepus
  module Saga
    module Sequel
      class Execution < ::Sequel::Model(:saga_executions)
        plugin :serialization, :json, :context
        include Lepus::Saga::ExecutionBehaviour
      end

      class StepAttempt < ::Sequel::Model(:saga_step_attempts)
        plugin :serialization, :json, :context_after
        include Lepus::Saga::StepAttemptBehaviour
      end
    end

    module Stores
      class Sequel < Base
        def create_execution(attributes)
          Saga::Sequel::Execution.create({id: SecureRandom.uuid_v7, context: {}}.merge(attributes))
        end

        def find_execution(id) = Saga::Sequel::Execution[id]

        def save_execution(execution)
          execution.save_changes
          execution
        end

        def with_lock(execution)
          execution.db.transaction do
            execution.lock!
            yield execution
          end
        end

        def increment_resume_count(execution)
          dataset = Saga::Sequel::Execution.where(id: execution.id)
          dataset.update(resume_count: ::Sequel[:resume_count] + 1, updated_at: Time.now)
          execution.values[:resume_count] = dataset.get(:resume_count)
        end

        def create_step_attempt(execution, attributes)
          Saga::Sequel::StepAttempt.create({id: SecureRandom.uuid_v7, saga_execution_id: execution.id}.merge(attributes))
        rescue ::Sequel::UniqueConstraintViolation => error
          raise DuplicateAttemptError, error.message
        end

        # stalled_executions, executions_for_resource, save_step_attempt,
        # step_attempts and the attempt queries are plain dataset filters.
      end
    end
  end
end
```

## Development

```bash
bin/setup
bundle exec rspec       # memory store
BUNDLE_GEMFILE=ci/Gemfile.no_activesupport bundle install
BUNDLE_GEMFILE=ci/Gemfile.no_activesupport bundle exec rspec  # without ActiveSupport or ActiveJob
bundle exec rubocop
bin/web-demo            # the web console on a seeded memory store
```

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
