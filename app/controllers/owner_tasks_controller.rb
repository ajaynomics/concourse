class OwnerTasksController < ApplicationController
  before_action :require_user, :require_organization

  FILTERS = %w[needs_you open done].freeze
  PER_PAGE = 50

  # Owner-side scope throughout: the signed-in person, across every agent
  # they own in this organization. A task outside it is a 404, the same as
  # a missing one.
  def index
    @filter = FILTERS.include?(params[:filter]) ? params[:filter] : "all"
    scope = Current.organization.tasks.involving_owner(Current.user)
    @counts = {
      "needs_you" => awaiting.count,
      "open" => scope.unfinished.count,
      "done" => scope.finished.count,
      "all" => scope.count
    }
    @page = [ params[:page].to_i, 1 ].max
    # One extra row says whether an older page exists without a second count.
    offset = (@page - 1) * PER_PAGE
    rows =
      if @filter == "needs_you"
        # A to-do list, oldest first: each row is something to act on, so
        # it stays one task to a row rather than one thread.
        awaiting.includes(:messages, caller_agent: :owner, recipient_agent: :owner)
          .order(status_at: :asc, id: :asc).offset(offset).limit(PER_PAGE + 1).to_a
      else
        Task::Context.page(scope, filtered(scope), offset: offset, limit: PER_PAGE + 1)
      end
    @older = rows.size > PER_PAGE
    @rows = rows.first(PER_PAGE)
  end

  def show
    scope = Current.organization.tasks.involving_owner(Current.user)
    @task = scope.includes(:messages, caller_agent: :owner, recipient_agent: :owner).find(params[:id])
    messages = @task.messages.includes(sender_agent: :owner).order(:created_at, :message_id)
    artifacts = @task.artifacts.order(:created_at, :artifact_id)
    # One thread, in the order things happened: messages and artifacts.
    @turns = (messages.to_a + artifacts.to_a).sort_by(&:created_at)
    @message_count = messages.size
    @context = Task::Context.new(@task.context_id, scope.where(context_id: @task.context_id)
      .includes(:messages, caller_agent: :owner, recipient_agent: :owner).to_a)
  end

  private

  def awaiting
    Current.organization.tasks.awaiting_owner(Current.user)
  end

  def filtered(scope)
    case @filter
    when "needs_you" then awaiting
    when "open" then scope.unfinished
    when "done" then scope.finished
    else scope
    end
  end
end
