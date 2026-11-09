module Concourse
  # Span attributes this app is willing to emit. Request and response bodies
  # are not an option on these instrumentations, and none of the hashes below
  # enable params or body capture. ActiveRecord stays out: a Solid Cable poll
  # would drown the cell, and query binds can be message text.
  module Telemetry
    INSTRUMENTATIONS = {
      "OpenTelemetry::Instrumentation::Rack" => {
        allowed_request_headers: [],
        allowed_response_headers: []
      },
      "OpenTelemetry::Instrumentation::ActionPack" => { span_naming: :semconv },
      "OpenTelemetry::Instrumentation::ActiveJob" => {},
      "OpenTelemetry::Instrumentation::Net::HTTP" => {}
    }.freeze
  end
end
