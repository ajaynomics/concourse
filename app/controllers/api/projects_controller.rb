class Api::ProjectsController < ApiController
  def index
    projects = Current.organization.projects.includes(:participations).order(:name)
    render json: { projects: projects.map(&:directory_entry) }
  end
end
