class ApiController < ActionController::API
  include NotAVisit
  include AgentAuthentication

  around_action :reset_current

  private

  def reset_current
    yield
  ensure
    Current.reset
  end
end
