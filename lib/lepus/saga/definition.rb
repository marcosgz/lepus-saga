# frozen_string_literal: true

module Lepus
  module Saga
    # Base class for declarative saga definitions.
    #
    #   class Orders::CheckoutSaga < Lepus::Saga::Definition
    #     saga_name "orders.checkout"
    #
    #     step :reserve_stock, compensate: :release_stock, retry: { attempts: 5 }
    #     step :persist_local
    #
    #     def reserve_stock
    #       context["reservation_id"] = ...
    #     end
    #   end
    #
    # Step methods run with `execution`, `context` and `resource` available.
    # Mutations to `context` are persisted when the step succeeds. Steps may
    # run more than once (at-least-once delivery) and must be idempotent.
    class Definition
      class << self
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@steps, [])
        end

        def saga_name(value = nil)
          if value
            @saga_name = value.to_s
            Lepus::Saga.register(@saga_name, self)
          end
          @saga_name
        end

        def partition(value = nil)
          @partition = value.to_s if value
          @partition || ((superclass < Definition) ? superclass.partition : "default")
        end

        def step(name, compensate: nil, **options)
          steps << Step.new(
            name: name.to_s,
            compensate: compensate&.to_s,
            retry_policy: RetryPolicy.build(options[:retry])
          )
        end

        def steps
          @steps ||= []
        end

        def find_step!(name)
          steps.find { |step| step.name == name.to_s } ||
            raise(UnknownStepError, "Unknown step #{name.inspect} in #{saga_name}")
        end

        def step_index(name)
          steps.index { |step| step.name == name.to_s }
        end

        # Starts a new execution and publishes its first step message.
        # Call it after the local transaction that created/changed the
        # resource has committed. `partition` overrides the definition's
        # partition for this execution only.
        def start(resource:, context: {}, correlation_id: nil, partition: nil)
          raise ArgumentError, "#{name} has no saga_name" if saga_name.blank?
          raise ArgumentError, "#{name} has no steps" if steps.empty?

          type, id = resource_reference(resource)
          execution = Lepus::Saga.store.create_execution(
            saga_name: saga_name,
            resource_type: type,
            resource_id: id,
            current_step: steps.first.name,
            context: context.stringify_keys,
            correlation_id: correlation_id,
            partition: partition,
            started_at: Time.current,
            last_progress_at: Time.current
          )
          Instrumentation.saga_event("saga.started", execution)
          StepProducer.publish_step(execution)
          execution
        end

        private

        def resource_reference(resource)
          case resource
          when Hash then [resource.fetch(:type).to_s, resource.fetch(:id).to_s]
          else [resource.class.name, Array(resource.id).first.to_s]
          end
        end
      end

      attr_reader :execution, :step_attempt

      def initialize(execution, step_attempt: nil)
        @execution = execution
        @step_attempt = step_attempt
      end

      def context = execution.context

      def resource
        @resource ||= find_resource
      end

      # Override for resources that need a custom lookup (composite keys etc).
      def find_resource
        execution.resource_type.constantize.find(execution.resource_id)
      end

      def complete!(reason = nil) = raise(Control::Complete, reason)

      def skip!(reason = nil) = raise(Control::Skip, reason)

      def fail!(reason) = raise(Control::Fail, reason)
    end
  end
end
