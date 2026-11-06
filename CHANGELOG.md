# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.1.0 - Unreleased
* Added: saga engine: `Lepus::Saga::Definition`, `Executor`, `ExecutorConsumer`, `StepProducer`, `QueueDepth`, `Instrumentation`, `LogSubscriber` and `Testing.drain`
* Added: `Lepus::Saga.configure` with `store`, `exchange_name` (default `"lepus.saga"`), `max_resumes`, `backlog_threshold`, `backlog_patience` and `stale_running_attempt_after`
* Added: ORM-agnostic persistence through `Lepus::Saga::Stores::Base`; `config.store = :name` requires `lepus/saga/stores/<name>`. ActiveRecord lives in the lepus-saga-active_record gem
* Added: `Lepus::Saga::ExecutionBehaviour` and `StepAttemptBehaviour` for adapters' record classes
* Added: `Lepus::Saga::Stores::Memory`, a thread-safe in-process store
* Added: `require "lepus/saga/rspec"` with the "a lepus saga store" and "a lepus saga engine" shared examples
* Added: `Lepus::Saga::ResumeStuckJob` ActiveJob for scheduling `Lepus::Saga.resume_stuck`
* Changed: `resume_stuck` increments `resume_count` atomically instead of writing back the value it read
