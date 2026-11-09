# Tells a person, through Web Push, that a task is waiting on one of their
# agents: a task sent to it that nobody has picked up, or a task it sent that
# the recipient paused for input. Agents usually act within seconds, so the
# alert waits a grace period and goes only if the status has not moved.
class OwnerAlertJob < ApplicationJob
  GRACE = 2.minutes

  queue_as :default
  discard_on ActiveJob::DeserializationError

  def perform(organization_id, task_id, status_at)
    organization = Organization.find_by(id: organization_id) # tenancy-ok: the job's own tenant argument
    task = organization&.tasks&.includes(:messages, caller_agent: :owner, recipient_agent: :owner)&.find_by(id: task_id)
    return unless task && task.status_at.utc.iso8601(6) == status_at

    alert = alert_for(task)
    return unless alert

    owner, key, agent, other = alert
    payload = {
      title: I18n.t("alerts.#{key}.title", agent: agent.qualified_handle, other: other.qualified_handle),
      body: I18n.t("alerts.#{key}.body", agent: agent.qualified_handle, other: other.qualified_handle),
      path: Rails.application.routes.url_helpers.my_task_path(task.organization, task),
      tag: "task-#{task.id}"
    }
    delivered = owner.push_subscriptions.to_a.count { |subscription| subscription.deliver(payload) }
    Rails.event.notify("concourse.owner.alerted", task_id: task.id, kind: key, delivered: delivered)
  end

  private

  # [owner to alert, i18n key, the agent being waited for, the other agent].
  # Only a current member hears about the organization's tasks.
  def alert_for(task)
    return unless task.participants_admitted?
    alert = if task.inbox? && task.state == "TASK_STATE_SUBMITTED"
      [ task.recipient_agent.owner, "submitted", task.recipient_agent, task.caller_agent ]
    elsif task.waiting_side == "caller"
      [ task.caller_agent.owner, task.state.delete_prefix("TASK_STATE_").downcase, task.recipient_agent, task.caller_agent ]
    end
    alert unless alert.nil? || alert.first.system? || !task.organization.memberships.exists?(user: alert.first)
  end
end
