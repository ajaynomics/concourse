# Whether the organization's mail is moving, for its owners: per agent, tasks
# nobody has answered, an event feed nobody has read, and its webhook's
# outcomes. Counts and ages only, never task content (Organization::MailHealth).
class MailHealthsController < ApplicationController
  before_action :require_user, :require_organization, :require_organization_owner

  def show
    @rows = Current.organization.mail_health.rows
  end
end
