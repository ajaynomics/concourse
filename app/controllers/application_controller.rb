class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  around_action :set_current_request

  helper_method :signed_in?, :live_updates?

  private

  # Pages refresh in place when the organization's tasks change. A page whose
  # layout must hold still under the pointer, such as a consent form, opts out.
  def live_updates?
    true
  end

  def set_current_request
    # Sessions from before people were users carry owner_id. They keep
    # working, under the new key from here on.
    session[:user_id] ||= session.delete(:owner_id) if session.key?(:owner_id)
    if session_expired?
      forget_push_subscription
      reset_session
    end
    Current.user = User.find_by(id: session[:user_id]) if session[:user_id].present?
    Current.organization = resolve_organization
    Concourse::Glitchtip.note(
      route: request.path,
      http_method: request.request_method,
      user: Current.user,
      organization: Current.organization,
      ip: request.remote_ip
    )
    yield
  ensure
    Current.reset
  end

  # The tenant is the organization in the path, and only ever one this
  # person belongs to. A page outside one, such as the join page, uses the
  # last one visited, or else their oldest membership. Everything downstream
  # scopes through Current.organization.
  def resolve_organization
    return if Current.user.nil?

    slug = request.path_parameters[:organization_slug]
    organization = if slug
      Current.user.organizations.find_by!(slug: slug)
    else
      Current.user.organizations.find_by(id: session[:organization_id]) || Current.user.first_organization
    end
    session[:organization_id] = organization&.id
    organization
  end

  # A browser's alerts belong to whoever is signed in on it. When the session
  # ends, however it ends, they stop, so the next person on a shared device
  # never gets the last one's alerts.
  def forget_push_subscription
    PushSubscription.where(endpoint: session[:push_endpoint]).destroy_all if session[:push_endpoint]
  end

  def session_expired?
    return false if session[:user_id].blank?

    signed_in_at = session[:signed_in_at]
    return true if signed_in_at.blank?

    Time.iso8601(signed_in_at) < Rails.application.config.x.session_max_age.ago
  rescue ArgumentError
    true
  end

  def signed_in?
    Current.user.present?
  end

  def require_user
    redirect_to sign_in_path unless signed_in?
  end

  # Signed in is not the same as a member. Someone who belongs nowhere sees
  # no data: the page to create an organization when anyone may, and
  # otherwise a plain account of why there is nothing here.
  def require_organization
    return if Current.organization

    if Organization.creation_open?
      redirect_to new_organization_path
    else
      render "organizations/none", status: :forbidden
    end
  end

  def require_organization_owner
    raise ActiveRecord::RecordNotFound unless Current.organization_owner?
  end
end
