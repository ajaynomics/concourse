# Tells an organization's owners that someone asked to join, or an agent is
# waiting to be approved. It waits a minute, so a burst becomes one alert, and
# reads the counts then: if everything was approved meanwhile, it says nothing.
# Web Push goes to owners who switched alerts on; email goes to owners with a
# verified address when SMTP is configured. Neither carries names or content.
class ApprovalAlertJob < ApplicationJob
  GRACE = 1.minute

  queue_as :default
  discard_on ActiveJob::DeserializationError

  # The newest request in a burst leaves its token in the cache; earlier jobs
  # see a different one and step aside. A lost entry can only duplicate an
  # alert, never drop one.
  # Runs after the commit that made someone wait. If queueing fails, that
  # person still waits on the page, so report it rather than fail their request.
  def self.schedule(organization_id)
    token = SecureRandom.hex(8)
    Rails.cache.write(cache_key(organization_id), token, expires_in: 1.hour)
    set(wait: GRACE).perform_later(organization_id, token)
  rescue StandardError => error
    Rails.error.report(error, handled: true, context: { organization_id: organization_id })
  end

  def self.cache_key(organization_id)
    "approval-alert/#{organization_id}"
  end

  def perform(organization_id, token = nil)
    newest = Rails.cache.read(self.class.cache_key(organization_id))
    return if newest && token && newest != token

    organization = Organization.find_by(id: organization_id) # tenancy-ok: the job's own tenant argument
    return unless organization&.approves_members?

    people = organization.join_requests.count
    agents = organization.agents.pending.count
    return if people.zero? && agents.zero?

    owners = organization.memberships.where(role: "owner").includes(:user).map(&:user).reject(&:system?)
    pushed = owners.sum { |owner| push(owner, organization, people + agents) }
    emailed = owners.count { |owner| email(owner, organization, people, agents) }
    Rails.event.notify("concourse.owner.approval_alerted", organization: organization.slug, people: people, agents: agents, pushed: pushed, emailed: emailed)
  end

  private

  def push(owner, organization, waiting)
    return 0 unless PushSubscription.configured?

    payload = {
      title: I18n.t("alerts.approvals.title", organization: organization.name),
      body: I18n.t("alerts.approvals.body", count: waiting),
      path: Rails.application.routes.url_helpers.edit_organization_path(organization),
      tag: "approvals-#{organization.id}"
    }
    owner.push_subscriptions.to_a.count { |subscription| subscription.deliver(payload) }
  rescue StandardError => error
    # One owner's bad subscription must not stop the others, or the email.
    Rails.error.report(error, handled: true, context: { organization_id: organization.id, user_id: owner.id })
    0
  end

  def email(owner, organization, people, agents)
    return false unless ApprovalMailer.configured? && owner.email.present? && owner.email_verified?

    ApprovalMailer.waiting(owner, organization, people: people, agents: agents).deliver_now
    true
  rescue StandardError => error
    # One unreachable mailbox must not stop the other owners' alerts.
    Rails.error.report(error, handled: true, context: { organization_id: organization.id, user_id: owner.id })
    false
  end
end
