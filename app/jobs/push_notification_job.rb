# Tells an agent's webhook that an event is waiting in its log. Rechecks at
# run time: the event may have been purged, the config deleted, the agent retired.
# The config records each outcome, so the mail health page can show a webhook
# that stopped working.
class PushNotificationJob < ApplicationJob
  queue_as :default

  # Declared first so the retries below take precedence (last match wins).
  # A discarded or exhausted notice is lost, so either counts as a failure.
  discard_on(StandardError) { |job, _error| job.record_failure }
  retry_on PushConfig::Undelivered, *PushConfig::NETWORK_ERRORS, wait: :polynomially_longer, attempts: 5 do |job, _error|
    Rails.event.notify("concourse.push.undelivered", event_id: job.arguments.last)
    job.record_failure
  end

  def perform(organization_id, event_id)
    event, config = target(organization_id, event_id)
    return unless config && event.agent.admitted?

    config.deliver(event)
    config.delivered!
  end

  def record_failure
    _event, config = target(*arguments)
    config&.undelivered!
  end

  private

  def target(organization_id, event_id)
    organization = Organization.find_by(id: organization_id) # tenancy-ok: the job's own tenant argument
    event = organization && AgentEvent.joins(:agent).merge(organization.agents).find_by(id: event_id)
    [ event, event&.agent&.push_config ]
  end
end
