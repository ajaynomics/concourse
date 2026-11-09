class SessionsController < ApplicationController
  # The identity provider owns authentication. This controller only turns a
  # verified identity into a Concourse session; which organizations that
  # person belongs to is Concourse's own business (User.upsert_from_identity!).

  def new
    redirect_to root_path if signed_in?
  end

  def create
    auth = request.env["omniauth.auth"]
    user = User.upsert_from_identity!(
      subject: auth&.uid,
      user_info: user_info_from(auth)
    )

    setup = Developer::SetupContinuation.restore(session[Developer::SetupContinuation::SESSION_KEY]) if Concourse.v3?
    connect = ConnectRequest.restore(session[ConnectRequest::SESSION_KEY])
    forget_push_subscription
    reset_session
    session[:user_id] = user.id
    session[:signed_in_at] = Time.current.iso8601
    session[Developer::SetupContinuation::SESSION_KEY] = setup.to_h if setup
    # Ahoy's cookies survive reset_session, so the visit that reached the
    # sign-in page is the one this user now owns.
    ahoy.authenticate(user)
    Rails.event.notify("concourse.user.signed_in", user_id: user.id)
    if connect
      redirect_to connect_path(connect.to_h)
    else
      redirect_to setup ? developer_setup_path : root_path
    end
  rescue User::UnauthorizedIdentity
    reset_session
    redirect_to sign_in_path, alert: t(".did_not_complete")
  end

  def destroy
    # Ajent publishes no end_session_endpoint, so there is no RP-initiated
    # logout: this clears Concourse's session and leaves the provider's intact.
    Rails.event.notify("concourse.user.signed_out", user_id: Current.user&.id)
    forget_push_subscription
    reset_session
    ahoy.reset_visit
    redirect_to sign_in_path, notice: t(".signed_out"), status: :see_other
  end

  def failure
    # A half-finished attempt leaves omniauth.state, omniauth.nonce and
    # omniauth.pkce.verifier in the session, where the next attempt would
    # replay them.
    reset_session
    redirect_to sign_in_path, alert: t(".did_not_complete")
  end

  private

  # Rails registers an anonymous browser callback; only the landing page
  # must remain readable without the signed-in app's browser features.
  def allow_browser(**)
    super unless action_name == "new"
  end

  # The IdP's UserInfo payload lands in extra.raw_info: what the provider
  # asserted, ahead of the gem's normalized copy in info.
  def user_info_from(auth)
    raw = auth&.dig("extra", "raw_info") || {}
    info = auth&.info || {}
    {
      "email" => raw["email"].presence || info["email"],
      "name" => raw["name"].presence || info["name"],
      "email_verified" => raw.key?("email_verified") ? raw["email_verified"] : info["email_verified"]
    }
  end
end
