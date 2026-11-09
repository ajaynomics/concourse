module Developer
  class SetupsController < ApplicationController
    before_action :require_v3

    # Chrome checks a form's redirect against the submitting document's CSP.
    # Resolve after the action: only a vetted, live, signed-in continuation
    # permits its exact receiver, without changing the global policy.
    content_security_policy do |policy|
      # Current is cleared before CSP middleware builds the lazy sources.
      setup_signed_in = signed_in?
      policy.form_action(*policy.directives["form-action"], -> { @setup && setup_signed_in ? "http://127.0.0.1:#{@setup.port}" : nil })
    end

    rescue_from ActionController::InvalidCrossOriginRequest do
      refuse("The form expired. Reload this page and try again.", status: :unprocessable_entity)
    end

    def show
      if request.query_string.present?
        session.delete(SetupContinuation::SESSION_KEY)
        fields = strict_fields(request.query_string, allowed: %w[port state])
        @setup = SetupContinuation.start(port: fields["port"], state: fields["state"]) if fields
        return refuse("Invalid setup link. Start setup again from your terminal.", status: :bad_request) unless @setup

        session[SetupContinuation::SESSION_KEY] = @setup.to_h
      else
        @setup = continuation
      end

      return redirect_to sign_in_path if @setup && !signed_in?

      load_memberships
    end

    def create
      @setup = continuation
      return refuse("Setup expired or already finished. Start setup again from your terminal.") unless @setup
      return redirect_to sign_in_path unless signed_in?
      return refuse("Invalid setup form.", status: :bad_request) unless request.query_string.empty? && request.media_type == "application/x-www-form-urlencoded"

      # Rack already read Falcon's non-rewindable input to parse parameters.
      # Its retained encoded form still preserves duplicates, unlike params.
      encoded = request.raw_post || request.get_header("rack.request.form_vars")
      fields = strict_fields(encoded, allowed: %w[organization_slug organization_name authenticity_token])
      return refuse("Invalid setup form.", status: :bad_request) unless fields

      slug, name = fields.values_at("organization_slug", "organization_name").map { |value| value.to_s.strip }
      return refuse("Choose an organization or create one, not both.") if slug.present? && name.present?

      if name.present?
        return refuse("Organization creation is closed. Ask an organization owner to admit your account.", status: :forbidden) unless Organization.creation_open?

        organization = Organization.found!(name: name, founder: Current.user)
      elsif slug.present?
        # Re-query current membership, never an unscoped organization lookup.
        organization = available_organizations.find_by(slug: slug)
        return refuse("Choose an organization you currently belong to.") unless organization
      else
        return refuse("Choose an organization or enter a name to create one.")
      end

      session.delete(SetupContinuation::SESSION_KEY)
      redirect_to @setup.completion_url(organization), status: :see_other, allow_other_host: true
    rescue ActiveRecord::RecordInvalid => error
      refuse(error.record.errors.full_messages.to_sentence)
    end

    private

    # Instrumentation parses parameters before before_actions, so malformed
    # bracket parameters must retain the same privacy headers as valid links.
    def process_action(...)
      protect_setup_response
      super
    rescue ActionController::BadRequest
      session.delete(SetupContinuation::SESSION_KEY) if request.get? || request.head?
      render plain: "Invalid setup request. Start setup again from your terminal.", status: :bad_request
    end

    def protect_setup_response
      response.set_header("Cache-Control", "no-store")
      # no-referrer makes browser form POST Origin:null, which Rails rejects.
      # Keep origin checks intact while withholding the path, query and nonce.
      response.set_header("Referrer-Policy", "strict-origin")
    end

    def require_v3
      head :not_found unless Concourse.v3?
    end

    def continuation
      setup = SetupContinuation.restore(session[SetupContinuation::SESSION_KEY])
      session.delete(SetupContinuation::SESSION_KEY) unless setup
      setup
    end

    # Rack's parsed hash loses duplicate keys. Validate the original encoding
    # instead, so arrays, duplicate fields and callback overrides fail closed.
    def strict_fields(encoded, allowed:)
      return unless encoded.is_a?(String)
      return if encoded.bytesize > 4096 || encoded.match?(/%(?![0-9a-fA-F]{2})/)

      pairs = URI.decode_www_form(encoded)
      return unless pairs.all? { |key, value| allowed.include?(key) && value.valid_encoding? }
      return unless pairs.map(&:first).uniq.size == pairs.size

      pairs.to_h
    rescue ArgumentError
      nil
    end

    def available_organizations
      Current.user.organizations.where.not(id: Current.user.removals.select(:organization_id))
    end

    def load_memberships
      @organizations = signed_in? ? available_organizations.order(:name).to_a : []
      @creation_open = Organization.creation_open?
    end

    def refuse(message, status: :unprocessable_entity)
      @error = message
      load_memberships
      render :show, status: status
    end
  end
end
