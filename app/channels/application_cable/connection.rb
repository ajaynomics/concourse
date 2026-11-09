module ApplicationCable
  # Live updates are for a signed-in person, read from the same session cookie
  # and held to the same 12 hours as the pages.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = signed_in_user || reject_unauthorized_connection
    end

    private

    def signed_in_user
      session = cookies.encrypted[Rails.application.config.session_options[:key]]
      return unless session.is_a?(Hash) && session["user_id"].present?

      signed_in_at = Time.iso8601(session["signed_in_at"].to_s)
      return if signed_in_at < Rails.application.config.x.session_max_age.ago

      User.find_by(id: session["user_id"])
    rescue ArgumentError
      nil
    end
  end
end
