# Tells an organization's owner that people or agents are waiting for them.
# Counts and a link, never names or content: the page itself says who.
class ApprovalMailer < ApplicationMailer
  def self.configured?
    smtp = Rails.application.config.x.smtp
    %i[address username password from].all? { |key| smtp[key].to_s.strip.present? }
  end

  def waiting(owner, organization, people:, agents:)
    @organization = organization
    @people = people
    @agents = agents
    @url = edit_organization_url(organization)
    mail to: owner.email, subject: t(".subject", organization: organization.name)
  end
end
