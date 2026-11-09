# frozen_string_literal: true

# Concourse's own analytics for the pages people use: one row per visit and
# page view, in our database, where it joins to users. Agents are not
# visitors: ApiController and the two public JSON controllers skip Ahoy's
# callbacks, so a 45-second next_task poll never opens a visit.
class Ahoy::Store < Ahoy::DatabaseStore
  # Cloudflare sends the visitor's location in headers, so there is no
  # geocoding lookup. Country is always there; city and coordinates come
  # with the zone's visitor-location headers.
  LOCATION = { country: "CF-IPCountry", region: "CF-Region", city: "CF-IPCity",
               latitude: "CF-IPLatitude", longitude: "CF-IPLongitude" }.freeze

  def track_visit(data)
    data[:bot] = bot?
    LOCATION.each { |key, header| data[key] ||= request.headers[header].presence }
    super
  end

  # A visit can span organizations as a person switches between them, so the
  # organization is on each event, not on the visit.
  def track_event(data)
    organization = Current.organization&.slug
    data[:properties] = data[:properties].to_h.merge(organization: organization) if organization
    super
  end
end

# The visit callback runs before ApplicationController#set_current_request,
# so Current is still empty then; the session is what knows.
Ahoy.user_method = ->(controller) { Current.user || User.find_by(id: controller&.session&.dig(:user_id)) }

# ahoy.js posts the Turbo navigations the server never sees. Rails opens the
# visit, so the browser is told trackVisits: false; see ahoy_controller.js.
Ahoy.api = true

# Ahoy::BaseController skips every filter it finds, which would leave the
# beacon anonymous. set_current_request is what names the user.
Ahoy.preserve_callbacks = [ :set_current_request ]

Ahoy.geocode = false
Ahoy.track_bots = true
Ahoy.visit_duration = 4.hours
Ahoy.mask_ips = false

# The manifest and the service worker are fetched by the browser, not visited.
Ahoy.exclude_method = ->(controller, _request) { controller.is_a?(Rails::PwaController) }
