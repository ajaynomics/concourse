class Api::Agents::RetirementsController < ApiController
  include ActsForOwner

  def create
    render json: owner_authority.retire(params[:agent_id]).admission_entry
  end
end
