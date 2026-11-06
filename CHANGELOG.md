# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.3.0 - Unreleased
* Added: brand mark and README logo
* Added: saga engine: `Lepus::Saga::Definition`, `Executor`, `ExecutorConsumer`, `StepProducer`, `QueueDepth`, `Instrumentation`, `LogSubscriber` and `Testing.drain`
* Added: `Lepus::Saga.configure` with `store`, `exchange_name` (default `"lepus.saga"`), `max_resumes`, `backlog_threshold`, `backlog_patience` and `stale_running_attempt_after`
* Added: ORM-agnostic persistence through `Lepus::Saga::Stores::Base`; `config.store = :name` requires `lepus/saga/stores/<name>`. ActiveRecord lives in the lepus-saga-active_record gem
* Added: `Lepus::Saga::ExecutionBehaviour` and `StepAttemptBehaviour` for adapters' record classes
* Added: `Lepus::Saga::Stores::Memory`, a thread-safe in-process store
* Added: `require "lepus/saga/rspec"` with the "a lepus saga store" and "a lepus saga engine" shared examples
* Added: `Lepus::Saga::ResumeStuckJob` ActiveJob for scheduling `Lepus::Saga.resume_stuck`
* Changed: `resume_stuck` increments `resume_count` atomically instead of writing back the value it read
* Added: optional query methods on `Stores::Base` (`queries?`, `list_executions`, `count_executions`, `execution_series`, `step_latency`, `failure_summary`, `saga_names`), implemented by `Stores::Memory`
* Added: the "a lepus saga query store" shared examples in `lepus/saga/rspec`
* Added: `Lepus::Saga.definitions`, the registry after eager loading the application
* Added: `current_step` filter on `list_executions` and `count_executions`
* Changed: `Stores::Memory` indexes step attempts by execution, so attempt lookups no longer scan every attempt
* Added: `Lepus::Saga::Web`, a mountable Rack console (overview, executions, execution, insights) over the query methods, with `authorize`, `read_only`, `title`, `default_poll_interval` and `max_rows`; `rack >= 2.2` is a dependency
* Added: `bin/web-demo`, the console on a seeded in-memory store
* Added: `progress_from`/`progress_to` (last_progress_at) and `error_class`/`error_step`/`error_from`/`error_to` (a failed attempt) filters on `list_executions` and `count_executions`, and `execution_count` on `failure_summary` rows
* Changed: the web console is a live map of saga lines with moving tokens, a 1 h/24 h/7 d range, full-width throughput, "Needs attention" and "Waiting the longest", and a poll picker; insights and the Barlow/Atkinson fonts are gone in favour of Overpass
* Added: `Web` `stalled_after` setting; `/api/sagas` counts stalled executions per step, `/api/moving` lists the moving executions of the busiest steps in one request, and `/api/executions` takes `stalled`, `error`, `error_step`, `error_from` and `error_to`
* Added: `HEAVY=1 bin/web-demo` seeds thousands of failures, a crowded step and hundreds of stalled executions
* Changed: ActiveSupport is no longer a dependency. Durations are seconds (`ActiveSupport::Duration` still works), store names resolve through `Lepus::Primitive::String` and the shared examples run without ActiveSupport
