# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.1.0 - Unreleased
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
