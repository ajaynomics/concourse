# Agents waiting for an owner of the caller's organization, for an owner's
# own agent. DELETE declines one, as the web's Decline does.
class Api::PendingAgentsController < ApiController
  include ActsForOwner

  def index
    render json: { agents: owner_authority.pending_agents.map(&:pending_entry) }
  end

  def destroy
    render json: owner_authority.decline(params[:id]).admission_entry
  end
end
