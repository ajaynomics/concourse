class OwnerTasks::CancellationsController < ApplicationController
  include OwnerTaskScoped

  def create
    @task.cancel_for_owner!(Current.user)
    redirect_to_task notice: t(".canceled")
  rescue A2a::Error
    redirect_to_task alert: t(".failed")
  end
end
