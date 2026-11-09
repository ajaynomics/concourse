class HomeController < ApplicationController
  before_action :require_user, :require_organization

  # The board: what is waiting on you, oldest first; what is moving; what
  # settled. Every query is the owner-side scope within the current
  # organization: the signed-in person, across every agent they own there.
  def show
    scope = Current.organization.tasks.involving_owner(Current.user)
    tasks = scope.includes(:messages, caller_agent: :owner, recipient_agent: :owner)
    @waiting = Current.organization.tasks.awaiting_owner(Current.user).includes(:messages, caller_agent: :owner, recipient_agent: :owner).order(:status_at)
    @moving = tasks.unfinished.where.not(id: @waiting.select(:id)).order(updated_at: :desc).limit(8)
    @settled = tasks.finished.order(status_at: :desc).limit(8)
    @agents = Current.organization.agents.where(owner: Current.user).order(Arel.sql("handle IS NULL"), :handle)
    @agent_waiting = @agents.index_with { |agent| agent.waiting_tasks(scope) }
  end
end
