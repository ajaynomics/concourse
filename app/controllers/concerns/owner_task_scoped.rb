# A task the signed-in person can see, through the owner-side scope in the
# current organization. Anything else is a 404, the same as a missing task.
module OwnerTaskScoped
  extend ActiveSupport::Concern

  included do
    before_action :require_user, :require_organization
    before_action :set_task
  end

  private

  def set_task
    @task = Current.organization.tasks.involving_owner(Current.user).includes(caller_agent: :owner, recipient_agent: :owner).find(params[:task_id])
  end

  # A conformance responder can answer with a direct Message and delete the
  # task (§3.1.1), so the task page may be gone by the time we redirect.
  def redirect_to_task(**flash)
    target = Current.organization.tasks.exists?(@task.id) ? my_task_path(Current.organization, @task) : my_tasks_path(Current.organization)
    redirect_to target, status: :see_other, **flash
  end
end
