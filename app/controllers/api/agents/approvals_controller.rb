class Api::Agents::ApprovalsController < ApiController
  include ActsForOwner

  def create
    render json: owner_authority.approve(params[:agent_id]).admission_entry
  end
end
