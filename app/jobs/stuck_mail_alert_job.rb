# Tells an organization's owners, through Web Push, when an agent's mail has
# been stuck for an hour: tasks nobody has answered, or an event feed nobody
# has read (Organization::MailHealth::STUCK). The 15-minute band never alerts:
# the recipient may be asking a person. Deliberately global: one recurring
# sweep looks at every organization, each through its own records.
#
# One alert per stuck episode. agents.stuck_alerted_at marks the agents the
# owners have heard about and clears once their mail moves again, so a later
# episode alerts again. Marked before sending: a failed push never repeats
# every run. Agent names only, never task content.
class StuckMailAlertJob < ApplicationJob
  queue_as :default

  def perform
    return unless PushSubscription.configured?

    Organization.find_each do |organization| # tenancy-ok: the sweep visits each organization, then scopes through it
      sweep(organization)
    rescue StandardError => error
      # One organization's failure must not stop the others' alerts.
      Rails.error.report(error, handled: true, context: { organization_id: organization.id })
    end
  end

  private

  def sweep(organization)
    stuck = organization.mail_health.stuck.map(&:agent)
    organization.agents.where.not(stuck_alerted_at: nil).where.not(id: stuck.map(&:id)).update_all(stuck_alerted_at: nil)

    fresh = stuck.select { |agent| agent.stuck_alerted_at.nil? }
    return if fresh.empty?

    organization.agents.where(id: fresh.map(&:id), stuck_alerted_at: nil).update_all(stuck_alerted_at: Time.current)
    owners = organization.memberships.owners.includes(:user).map(&:user).reject(&:system?)
    pushed = owners.sum { |owner| push(owner, organization, fresh.map(&:qualified_handle)) }
    Rails.event.notify("concourse.owner.stuck_mail_alerted", organization: organization.slug, agents: fresh.size, pushed: pushed)
  end

  def push(owner, organization, handles)
    payload = {
      title: I18n.t("alerts.stuck_mail.title", count: handles.size, agent: handles.first),
      body: I18n.t("alerts.stuck_mail.body", count: handles.size, agents: handles.to_sentence),
      path: Rails.application.routes.url_helpers.mail_health_path(organization),
      tag: "mail-health-#{organization.id}"
    }
    owner.push_subscriptions.to_a.count { |subscription| subscription.deliver(payload) }
  rescue StandardError => error
    # One owner's bad subscription must not stop the others.
    Rails.error.report(error, handled: true, context: { organization_id: organization.id, user_id: owner.id })
    0
  end
end
