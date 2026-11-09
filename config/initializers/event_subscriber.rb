# frozen_string_literal: true

# Rails.event is the 8.1 way to leave a machine-readable line. Request traces
# already exist. Events are logs.
module Concourse
  class JsonLogSubscriber
    def emit(event)
      Rails.logger.info(format_event(event))
    end

    private

    def format_event(event)
      {
        event: event[:name],
        payload: event[:payload],
        context: event[:context],
        tags: event[:tags],
        timestamp: format_timestamp(event[:timestamp]),
        source: format_source(event[:source_location])
      }.compact_blank.to_json
    end

    def format_timestamp(nanoseconds)
      return unless nanoseconds

      Time.at(nanoseconds / 1_000_000_000.0).utc.iso8601(6)
    end

    def format_source(source_location)
      return unless source_location

      "#{source_location[:filepath]}:#{source_location[:lineno]}"
    end
  end

  # The Ruby SDK is traces-only. Events post OTLP/JSON logs to the same
  # collector the trace exporter uses, rather than asking the cell to scrape
  # container stdout.
  class OtlpLogSubscriber
    def emit(event)
      return if ENV["OTEL_EXPORTER_OTLP_ENDPOINT"].blank?

      deliver(body_for(event))
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: { subscriber: "Concourse::OtlpLogSubscriber" })
    end

    def body_for(event)
      {
        resourceLogs: [
          {
            resource: { attributes: resource_attributes },
            scopeLogs: [
              {
                scope: { name: ENV.fetch("OTEL_SERVICE_NAME", "concourse") },
                logRecords: [
                  {
                    timeUnixNano: (event[:timestamp] || (Time.now.to_f * 1_000_000_000).to_i).to_s,
                    severityNumber: 9,
                    severityText: "INFO",
                    body: { stringValue: event[:name].to_s },
                    attributes: payload_attributes(event[:payload])
                  }
                ]
              }
            ]
          }
        ]
      }
    end

    private

    # Delivery stays synchronous: the timeouts bound it. A refused collector
    # is reported, not raised.
    def deliver(body)
      uri = URI.join("#{ENV["OTEL_EXPORTER_OTLP_ENDPOINT"].chomp("/")}/", "v1/logs")
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 1, read_timeout: 2) do |http|
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        otlp_headers.each { |key, value| request[key] = value }
        request.body = JSON.generate(body)
        response = http.request(request)
        unless response.is_a?(Net::HTTPSuccess)
          Rails.error.report(
            StandardError.new("collector refused logs: #{response.code}"),
            handled: true, context: { subscriber: "Concourse::OtlpLogSubscriber", status: response.code }
          )
        end
      end
    end

    def resource_attributes
      attrs = {
        "service.name" => ENV.fetch("OTEL_SERVICE_NAME", "concourse"),
        "service.version" => Concourse.revision,
        "deployment.environment" => ENV.fetch("DEPLOYMENT_ENVIRONMENT", Rails.env.to_s)
      }
      # OTEL_RESOURCE_ATTRIBUTES fills gaps only: the names above win, the same
      # precedence the trace resource in the OpenTelemetry initializer uses.
      ENV.fetch("OTEL_RESOURCE_ATTRIBUTES", "").split(",").each do |pair|
        key, value = pair.split("=", 2)
        attrs[key.strip] ||= value.strip if key.present? && value.present?
      end
      attrs.compact.map { |key, value| otlp_string(key, value) }
    end

    def payload_attributes(payload)
      (payload || {}).filter_map do |key, value|
        next if value.nil?
        # Message and artifact bodies must not leave the app. A caller that
        # puts them on an event still has the line dropped here.
        next if content_key?(key)

        case value
        when Integer then { key: key.to_s, value: { intValue: value.to_s } }
        when Float then { key: key.to_s, value: { doubleValue: value } }
        when true, false then { key: key.to_s, value: { boolValue: value } }
        else otlp_string(key, value)
        end
      end
    end

    def content_key?(key)
      key.to_s.match?(/parts|message|text|raw|data|content/)
    end

    def otlp_string(key, value)
      { key: key.to_s, value: { stringValue: value.to_s } }
    end

    def otlp_headers
      ENV.fetch("OTEL_EXPORTER_OTLP_HEADERS", "").split(",").each_with_object({}) do |pair, headers|
        key, value = pair.split("=", 2)
        headers[key.strip] = value.strip if key.present? && value.present?
      end
    end
  end
end

# Only this app's own events. A bare subscribe receives every Rails.event
# notification in the process, so the first gem that emits its own would land
# in the logs unasked.
Rails.event.subscribe(Concourse::JsonLogSubscriber.new) { |event| event[:name].start_with?("concourse.") }
Rails.event.subscribe(Concourse::OtlpLogSubscriber.new) { |event| event[:name].start_with?("concourse.") }
