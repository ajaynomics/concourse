# Any member names and describes a project; only an owner deletes one.
# Which agents are in it is up to each agent and its owner.
class ProjectsController < ApplicationController
  before_action :require_user, :require_organization
  before_action :set_project, only: %i[edit update destroy]
  before_action :require_organization_owner, only: :destroy

  def index
    @projects = Current.organization.projects.includes(:participations).order(:name)
  end

  def new
    @project = Current.organization.projects.new
  end

  def create
    @project = Current.organization.projects.new(project_params)
    if @project.save
      redirect_to agents_path(Current.organization, project: @project.slug), notice: t(".created", name: @project.name), status: :see_other
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @project.update(project_params)
      redirect_to agents_path(Current.organization, project: @project.slug), notice: t(".saved"), status: :see_other
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @project.destroy!
    redirect_to projects_path(Current.organization), notice: t(".deleted", name: @project.name), status: :see_other
  end

  private

  def set_project
    @project = Current.organization.projects.find_by!(slug: params[:slug])
  end

  def project_params
    params.expect(project: %i[name description])
  end
end
