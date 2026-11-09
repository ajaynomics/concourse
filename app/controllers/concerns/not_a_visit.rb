# Agent requests are machines on a credential, not people on a page. Ahoy
# hooks every controller; this takes it back off the agent-facing ones.
module NotAVisit
  extend ActiveSupport::Concern

  included do
    skip_before_action :track_ahoy_visit, raise: false
    skip_around_action :set_ahoy_request_store, raise: false
  end
end
