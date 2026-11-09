# The key is the one Rails 8.1 would have minted (`_#{railtie_name}_session`).
# Setting session_store here skips that default, so the key has to be named.
# Twelve hours, then the person signs in again through Ajent. The cookie
# expiry is the browser half; ApplicationController also rejects a session
# whose signed_in_at is older than this, so a copied cookie does not slide.
Rails.application.config.x.session_max_age = 12.hours
Rails.application.config.session_store :cookie_store,
  key: "_concourse_session",
  expire_after: Rails.application.config.x.session_max_age
