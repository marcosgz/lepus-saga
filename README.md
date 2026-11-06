# Lepus::Saga

Linear sagas on top of [Lepus](https://github.com/marcosgz/lepus).

A saga is an ordered list of steps with optional compensations and retry policies. State lives in a store: one execution per saga run and one step attempt per try of a step. Messages on the saga exchange only point at the next unit of work, so duplicate deliveries are fenced out, and lost messages are healed by re-publishing whatever the execution record says is current.

This gem is the engine and has no ORM dependency. Storage comes from an adapter:

| Store | Gem | `config.store =` |
| --- | --- | --- |
| ActiveRecord (PostgreSQL, MySQL/MariaDB, SQLite) | [lepus-saga-active_record](https://github.com/marcosgz/lepus-saga-active_record) | `:active_record` |
| In-process memory (tests, scripts) | this gem | `:memory` |

## Installation

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
  config.backlog_patience = 2.hours              # stall time behind a backlog before one re-publish
  config.stale_running_attempt_after = 5.minutes # running attempts older than this are closed as abandoned
end
```

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
Lepus::Saga.resume_stuck(older_than: 15.minutes, limit: 100, max_resumes: Lepus::Saga.config.max_resumes)
```

`retry` and `compensate` lock the execution, reload the record you pass in place and return it.

`resume_stuck` re-publishes executions whose cursor has not moved for `older_than`. An execution re-published `max_resumes` times without progress is compensated, or failed when there is nothing to undo. While a partition's queue holds more than `backlog_threshold` ready messages, its executions are left alone and re-published once after `backlog_patience`.

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

  def perform = Lepus::Saga.resume_stuck(older_than: 15.minutes)
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

## Instrumentation and logging

Events go through `Lepus.instrument`, so they are suffixed with `.lepus`: `saga.started`, `saga.step.started`, `saga.step.finished`, `saga.step.failed`, `saga.step.skipped`, `saga.completed`, `saga.compensation_started`, `saga.compensated`, `saga.failed`, `saga.compensation_failed`, `saga.resumed`. The payload carries the execution record under `:execution`.

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
bundle exec rubocop
```

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
