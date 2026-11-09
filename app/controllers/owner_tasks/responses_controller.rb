class OwnerTasks::ResponsesController < ApplicationController
  include OwnerTaskScoped

  def create
    @task.respond_for_owner!(Current.user, side: params[:side], text: params[:text], state: params[:state])
    redirect_to_task notice: t(".sent")
  rescue A2a::Error
    redirect_to_task alert: t(".failed")
  end
end
