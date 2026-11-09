class Api::AgentsController < ApiController
  def index
    agents = A2a::Exchange.find_agents(Current.organization, query: params[:query], project: params[:project], limit: params.fetch(:limit, Agent::DIRECTORY_PAGE))
    render json: { agents: agents.map(&:directory_entry) }
  rescue A2a::Error
    render json: { error: "unknown_project" }, status: :not_found
  end
end
