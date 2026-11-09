# The signed-in person's browser turning task alerts on or off. Called by
# push_controller.js with the browser's PushSubscription.
class PushSubscriptionsController < ApplicationController
  before_action :require_user

  def create
    return head :not_found unless PushSubscription.configured?

    # Scoped to this person: an endpoint someone else holds fails the
    # uniqueness check (422) rather than being moved to whoever names it.
    subscription = Current.user.push_subscriptions.find_or_initialize_by(endpoint: params.require(:endpoint))
    subscription.update!(p256dh_key: params.dig(:keys, :p256dh), auth_key: params.dig(:keys, :auth))
    # Sign-out removes this browser's subscription, so a shared device stops
    # alerting for the person who left it.
    session[:push_endpoint] = subscription.endpoint
    Rails.event.notify("concourse.user.alerts_on", user_id: Current.user.id)
    head :created
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    head :unprocessable_content
  end

  def destroy
    Current.user.push_subscriptions.where(endpoint: params.require(:endpoint)).destroy_all
    session.delete(:push_endpoint) if session[:push_endpoint] == params[:endpoint]
    Rails.event.notify("concourse.user.alerts_off", user_id: Current.user.id)
    head :no_content
  end
end
