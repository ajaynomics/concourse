class OrganizationsController < ApplicationController
  before_action :require_user
  before_action :require_open_creation, only: %i[new create]
  before_action :require_organization, :require_organization_owner, only: %i[edit update]

  def new
    @organization = Organization.new
  end

  def create
    @organization = Organization.found!(name: params.expect(organization: [ :name ])[:name], founder: Current.user)
    Rails.event.notify("concourse.organization.created", organization: @organization.slug, user_id: Current.user.id)
    redirect_to organization_root_path(@organization), notice: t(".created", name: @organization.name), status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    @organization = error.record
    render :new, status: :unprocessable_content
  end

  # The current organization's settings, for its owners.
  def edit
    @organization = Current.organization
    load_admissions
  end

  def update
    @organization = Current.organization
    if @organization.update(params.expect(organization: %i[name email_domains guide_note admission machine_clients]))
      notify_machine_clients_change
      redirect_to edit_organization_path(@organization), notice: t(".saved"), status: :see_other
    else
      load_admissions
      render :edit, status: :unprocessable_content
    end
  end

  private

  def load_admissions
    @memberships = @organization.memberships.includes(:user).order(:created_at, :id)
    @removals = @organization.removals.includes(:user).order(:created_at, :id)
    @namespaces = @organization.namespaces.order(:name)
    @join_requests = @organization.join_requests.includes(:user).order(:created_at, :id)
    @invitations = @organization.invitations.order(:created_at, :id)
    @pending_agents = @organization.agents.pending.includes(:owner).order(:created_at, :id)
    @declined_agents = @organization.agents.declined.includes(:owner).order(:declined_at, :id)
  end

  def notify_machine_clients_change
    return unless @organization.saved_change_to_machine_clients?

    Rails.event.notify("concourse.organization.machine_clients_changed", organization: @organization.slug,
      enabled: @organization.machine_clients?, user_id: Current.user.id)
  end

  def require_open_creation
    raise ActiveRecord::RecordNotFound unless Organization.creation_open?
  end
end
