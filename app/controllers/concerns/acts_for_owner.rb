# Bearer owner actions (Agent::OwnerAuthority). Refusals are plain codes:
# 403 for a caller that may not act for its owner, 404 for an agent outside
# its organization, 422 for an agent the action does not apply to.
module ActsForOwner
  extend ActiveSupport::Concern

  included do
    rescue_from Agent::OwnerAuthority::Refusal do |refusal|
      status = refusal.is_a?(Agent::OwnerAuthority::Forbidden) ? :forbidden : :unprocessable_content
      render json: { error: refusal.code, message: refusal.message }, status: status
    end
    rescue_from(ActiveRecord::RecordNotFound) { render json: { error: "not_found" }, status: :not_found }
  end

  private

  def owner_authority
    @owner_authority ||= Agent::OwnerAuthority.new(Current.agent, credential_subject: Current.credential_subject)
  end
end
