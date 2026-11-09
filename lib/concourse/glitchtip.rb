module Concourse
  # What an error report may contain. Message and artifact bodies are not
  # among them: a JSON-RPC body is not filtered by key name, so the request
  # body is never attached, and stack frames do not keep locals.
  module Glitchtip
    module_function

    def apply(sentry)
      # send_default_pii= rebuilds data_collection from the legacy flag.
      # Set the locals flag first so that rebuild does not turn them back on,
      # then force bodies off either way.
      sentry.include_local_variables = false
      sentry.send_default_pii = false
      sentry.data_collection.http_bodies = []
      sentry.data_collection.stack_frame_variables = false
      sentry.before_send = ->(event, hint) { scrub(event, hint) }
    end

    # Route, HTTP method, JSON-RPC method, and who: the user by handle,
    # name, email, and IP, their organization, and the calling agent. Not
    # the body.
    def note(route:, http_method:, agent: nil, user: nil, organization: nil, rpc_method: nil, ip: nil)
      return unless defined?(Sentry) && Sentry.initialized?

      user ||= agent&.owner
      organization ||= agent&.organization
      Sentry.set_user({ id: user&.id, username: user&.handle, email: user&.email, name: user&.name,
        ip_address: ip }.compact)
      Sentry.set_tags({ route: route, http_method: http_method, agent: agent&.qualified_handle,
        organization: organization&.slug }.compact)
      Sentry.set_context("concourse", {
        agent_id: agent&.id,
        user_id: user&.id,
        organization_id: organization&.id,
        rpc_method: rpc_method
      }.compact)
    end

    def scrub(event, _hint)
      request = event.request
      if request
        request.data = nil
        request.cookies = nil
        request.query_string = nil
        request.env = nil
      end
      event
    end
  end
end
