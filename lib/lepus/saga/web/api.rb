# frozen_string_literal: true

require "time"

module Lepus
  module Saga
    module Web
      # The JSON API under /api. Reads need the store's query methods; the
      # two actions are POSTs guarded against cross-site requests: they need a
      # JSON body, the X-Lepus-Saga header and a same-origin Origin (or
      # Referer when the browser sends no Origin).
      class Api
        class Error < StandardError
          attr_reader :status

          def initialize(status, message)
            @status = status
            super(message)
          end
        end

        ROUTES = [
          ["GET", %r{\A/me\z}, :me],
          ["GET", %r{\A/sagas\z}, :sagas],
          ["GET", %r{\A/executions\z}, :executions],
          ["GET", %r{\A/executions/(?<id>[^/]+)\z}, :execution],
          ["GET", %r{\A/series\z}, :series],
          ["GET", %r{\A/insights/failures\z}, :failures],
          ["GET", %r{\A/insights/latency\z}, :latency],
          ["GET", %r{\A/stalled\z}, :stalled],
          ["POST", %r{\A/executions/(?<id>[^/]+)/retry\z}, :retry_execution],
          ["POST", %r{\A/executions/(?<id>[^/]+)/compensate\z}, :compensate_execution]
        ].freeze
        ACTIONS = {retry_execution: :retry, compensate_execution: :compensate}.freeze
        CSRF_HEADER = "HTTP_X_LEPUS_SAGA"
        DEFAULT_WINDOW = 24 * 3600
        SERIES_BUCKETS = [60, 300, 600, 900, 1800, 3600, 7200, 10_800, 21_600, 43_200, 86_400].freeze
        SERIES_TARGET = 90
        STOPPED_STATUSES = %w[failed compensation_failed].freeze
        RELATED_LIMIT = 20

        def initialize(config)
          @config = config
        end

        def call(env)
          request = Rack::Request.new(env)
          method, _pattern, action, match = route(request)
          raise Error.new(404, "Not found") unless action
          raise Error.new(405, "Method not allowed") unless request.request_method == method

          authorize_action!(request, ACTIONS[action]) if ACTIONS.key?(action)
          json(200, send(action, request, **match.named_captures.transform_keys(&:to_sym)))
        rescue Error => error
          json(error.status, error: error.message)
        rescue NotRetryableError, UnknownSagaError => error
          json(409, error: error.message)
        rescue NotImplementedError
          json(501, error: "The saga store does not implement the query methods")
        rescue ArgumentError => error
          json(400, error: error.message)
        end

        private

        attr_reader :config

        def store = config.store

        def route(request)
          path = request.path_info.empty? ? "/" : request.path_info
          candidates = ROUTES.filter_map { |method, pattern, action| [method, pattern, action, pattern.match(path)] if pattern.match?(path) }
          candidates.find { |method, *| method == request.request_method } || candidates.first
        end

        def me(request)
          {
            title: config.title,
            version: VERSION,
            read_only: config.read_only ? true : false,
            queries: store.queries?,
            poll_interval: config.default_poll_interval,
            poll_intervals: Configuration::POLL_INTERVALS,
            actions: ACTIONS.values.to_h { |action| [action, config.allowed?(request.env, action)] }
          }
        end

        def sagas(request)
          from, to = window(request)
          live = store.count_executions(group_by: %i[saga_name status current_step], status: ExecutionBehaviour::IN_PROGRESS_STATUSES)
          stopped = store.count_executions(group_by: %i[saga_name status current_step], status: STOPPED_STATUSES, from: from, to: to)
          totals = store.count_executions(group_by: %i[saga_name status], from: from, to: to)
          failures = store.failure_summary(from: from, to: to, limit: 500)
          definitions = Lepus::Saga.definitions
          names = (definitions.keys + store.saga_names + totals.keys.map(&:first)).uniq.sort

          sagas = names.map do |name|
            Serializer.definition(name, definitions[name]).merge(
              stations: stations(name, live.merge(stopped), failures),
              totals: totals.filter_map { |(saga, status), count| [status, count] if saga == name }.to_h
            )
          end
          {from: Serializer.time(from), to: Serializer.time(to), sagas: sagas}
        end

        def stations(name, counts, failures)
          stations = Hash.new { |hash, step| hash[step] = {attempt_failures: 0} }
          counts.each do |(saga, status, step), count|
            stations[step][status] = count if saga == name
          end
          failures.each do |failure|
            stations[failure[:step_name]][:attempt_failures] += failure[:count] if failure[:saga_name] == name
          end
          stations
        end

        def executions(request)
          limit = integer(request, "limit", default: 50, range: 1..200)
          rows = store.list_executions(**filters(request), before_id: param(request, "before"), limit: limit + 1)
          {
            executions: rows.first(limit).map { |execution| Serializer.execution(execution) },
            next_before: (rows[limit - 1].id if rows.size > limit)
          }
        end

        def execution(_request, id:)
          execution = find!(id)
          definition = Lepus::Saga.definitions[execution.saga_name]
          related = store.executions_for_resource(execution.resource_type, execution.resource_id)
            .reject { |other| other.id == execution.id }.first(RELATED_LIMIT)
          {
            execution: Serializer.execution(execution, context: true),
            definition: Serializer.definition(execution.saga_name, definition),
            attempts: store.step_attempts(execution).map { |attempt| Serializer.attempt(attempt) },
            related: related.map { |other| Serializer.execution(other) }
          }
        end

        def series(request)
          from, to = window(request)
          bucket = integer(request, "bucket", default: series_bucket(to - from), range: 1..)
          result = store.execution_series(from: from, to: to, bucket: bucket, saga_name: list(request, "saga"), max_rows: config.max_rows)
          {
            from: Serializer.time(from), to: Serializer.time(to), bucket: bucket, truncated: result[:truncated],
            rows: result[:rows].map { |start, counts| {t: Serializer.time(start), **counts} }
          }
        end

        def failures(request)
          from, to = window(request)
          limit = integer(request, "limit", default: 20, range: 1..200)
          rows = store.failure_summary(from: from, to: to, saga_name: list(request, "saga"), limit: limit)
          {from: Serializer.time(from), to: Serializer.time(to), failures: rows.map { |row| row.merge(last_seen_at: Serializer.time(row[:last_seen_at])) }}
        end

        def latency(request)
          from, to = window(request)
          result = store.step_latency(from: from, to: to, saga_name: list(request, "saga"), max_rows: config.max_rows)
          rows = result[:rows].map { |row| row.merge(row.slice(:p50, :p95, :p99, :max).transform_values { |ms| ms&.round(1) }) }
          {from: Serializer.time(from), to: Serializer.time(to), rows: rows, truncated: result[:truncated]}
        end

        def stalled(request)
          minutes = integer(request, "minutes", default: 15, range: 1..)
          limit = integer(request, "limit", default: 50, range: 1..200)
          rows = store.stalled_executions(before: Time.current - minutes * 60).first(limit)
          {older_than_minutes: minutes, executions: rows.map { |execution| Serializer.execution(execution) }}
        end

        def retry_execution(_request, id:)
          {execution: Serializer.execution(Lepus::Saga.retry(find_actionable!(id)))}
        end

        def compensate_execution(request, id:)
          reason = body(request)["reason"].to_s.strip.presence || "manually compensated"
          {execution: Serializer.execution(Lepus::Saga.compensate(find_actionable!(id), reason: reason))}
        end

        def authorize_action!(request, action)
          raise Error.new(403, "The console is read-only") if config.read_only
          raise Error.new(403, "Forbidden") unless config.allowed?(request.env, action)
          raise Error.new(403, "Cross-site request rejected") unless same_origin?(request)
        end

        def same_origin?(request)
          return false unless request.media_type == "application/json"
          return false if request.get_header(CSRF_HEADER).to_s.empty?

          origin = request.get_header("HTTP_ORIGIN") || referer_origin(request.referer)
          !origin.nil? && origin == request.base_url
        end

        def referer_origin(referer)
          return if referer.nil?

          uri = URI.parse(referer)
          port = (uri.port == uri.default_port) ? "" : ":#{uri.port}"
          "#{uri.scheme}://#{uri.host}#{port}" if uri.host
        rescue URI::InvalidURIError
          nil
        end

        def find!(id)
          store.find_execution(id) || raise(Error.new(404, "Execution #{id} not found"))
        end

        def find_actionable!(id)
          execution = find!(id)
          return execution if Lepus::Saga.definitions.key?(execution.saga_name)

          raise Error.new(409, "Saga #{execution.saga_name} is not loaded in this process")
        end

        def body(request)
          content = request.body&.read.to_s
          return {} if content.empty?

          data = JSON.parse(content)
          data.is_a?(Hash) ? data : {}
        rescue JSON::ParserError
          raise Error.new(400, "Invalid JSON body")
        end

        def filters(request)
          {
            saga_name: list(request, "saga"),
            status: list(request, "status"),
            current_step: list(request, "step"),
            partition: param(request, "partition"),
            resource: param(request, "resource"),
            from: time(request, "from"),
            to: time(request, "to")
          }
        end

        def window(request)
          to = time(request, "to") || Time.current
          from = time(request, "from") || (to - DEFAULT_WINDOW)
          raise ArgumentError, "from must be before to" unless from < to

          [from, to]
        end

        def series_bucket(span)
          SERIES_BUCKETS.find { |seconds| span / seconds <= SERIES_TARGET } || SERIES_BUCKETS.last
        end

        def param(request, name)
          value = request.GET[name]
          value.is_a?(String) ? value.strip.presence : nil
        end

        def list(request, name)
          param(request, name)&.split(",")&.map(&:strip)&.reject(&:empty?).presence
        end

        def time(request, name)
          value = param(request, name)
          value && Time.iso8601(value)
        rescue ArgumentError
          raise ArgumentError, "#{name} must be an ISO 8601 time"
        end

        def integer(request, name, default:, range:)
          value = param(request, name)
          return default if value.nil?

          number = Integer(value, exception: false)
          raise ArgumentError, "#{name} must be an integer in #{range}" unless number && range.cover?(number)

          number
        end

        def json(status, data)
          [status, {"content-type" => "application/json; charset=utf-8", "cache-control" => "no-store"}, [JSON.generate(data)]]
        end
      end
    end
  end
end
