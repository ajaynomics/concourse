class AgentsController < ApplicationController
  before_action :require_user, :require_organization
  before_action :set_agent, except: :index
  before_action :require_own_agent, only: %i[edit update]

  def index
    @projects = Current.organization.projects.order(:name)
    @project = @projects.find_by!(slug: params[:project]) if params[:project].present?
    @agents = Current.organization.agents.listed
    @agents = @agents.in_project(@project) if @project
    @pending_agents = Current.organization_owner? ? Current.organization.agents.pending.includes(:owner).order(:created_at, :id) : Agent.none
  end

  def show
    # Owner-side scope: the signed-in person, across every agent they own.
    scope = Current.organization.tasks.involving_owner(Current.user)
    @tasks = scope.where("recipient_agent_id = :id OR caller_agent_id = :id", id: @agent.id)
      .includes(caller_agent: :owner, recipient_agent: :owner).order(updated_at: :desc).limit(50)
    @waiting = @agent.waiting_tasks(scope)
  end

  def edit
  end

  # The person edits their own agent's name, description, and projects, and
  # may move it to another of their organizations or under one of this
  # organization's namespaces. The handle is claimed once (update_card), and
  # the agent's next update_card wins.
  def update
    attributes = agent_params
    slugs = attributes.delete(:project_slugs)
    moved = false
    # Moves and native receipt reservations share the agent's route lock.
    saved = @agent.with_lock do
      @agent.assign_attributes(attributes)
      moved = @agent.organization_id_changed?
      @agent.projects = Current.organization.projects.where(slug: slugs.compact_blank) if slugs && !moved
      @agent.save(context: :owner_edit) || raise(ActiveRecord::Rollback)
    end
    if saved
      Rails.event.notify("concourse.owner.card_edited", agent_id: @agent.id)
      # A moved agent has left this organization; follow it.
      notice = moved ? t(".moved", organization: @agent.organization.name) : t(".saved")
      redirect_to agent_path(@agent.organization, @agent.prefix, @agent.handle), notice: notice, status: :see_other
    else
      render :edit, status: :unprocessable_content
    end
  end

  private

  def set_agent
    @agent = Current.organization.agents.named(params[:owner_handle], params[:handle])
    raise ActiveRecord::RecordNotFound unless @agent
  end

  def require_own_agent
    raise ActiveRecord::RecordNotFound unless @agent.owner_id == Current.user.id
  end

  # An organization the person does not belong to is refused by the model,
  # the same as one with open tasks left behind.
  def agent_params
    params.expect(agent: [ :name, :description, :organization_id, :namespace_id, project_slugs: [] ])
  end
end
