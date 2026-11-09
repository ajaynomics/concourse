# frozen_string_literal: true

# Traces go to the configured OTLP collector. That collector is a
# pass-through transport for every adopting app, so any never-emit policy this
# app has is enforced here, app-side, and never delegated to it.
return unless defined?(OpenTelemetry)

# No endpoint, no OpenTelemetry: installing instrumentation logs a line per
# library, and without a collector telemetry should change nothing.
return if ENV["OTEL_EXPORTER_OTLP_ENDPOINT"].blank?

require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry/instrumentation/all"

OpenTelemetry::SDK.configure do |c|
  service_name = ENV.fetch("OTEL_SERVICE_NAME", "concourse")

  # Attributes from OTEL_RESOURCE_ATTRIBUTES merge into the default resource,
  # and the keys named here win on conflict. deployment.environment comes from
  # DEPLOYMENT_ENVIRONMENT rather than Rails.env, which is production on every
  # deployed host.
  #
  # service.version is what makes a trace attributable to a deploy. Kamal sets
  # KAMAL_VERSION on every container it runs.
  c.resource = OpenTelemetry::SDK::Resources::Resource.create(
    {
      "service.name" => service_name,
      "service.version" => Concourse.revision,
      "deployment.environment" => ENV.fetch("DEPLOYMENT_ENVIRONMENT", Rails.env.to_s)
    }.compact
  )
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new
    )
  )
  # Requests, jobs, and outbound HTTP. Query spans stay out. Bodies and
  # params are not span attributes: Telemetry::INSTRUMENTATIONS is the list.
  Concourse::Telemetry::INSTRUMENTATIONS.each do |name, options|
    c.use name, options
  end
end
