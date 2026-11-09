# Mail is only for owner alerts and only when config/smtp.yml is complete.
# Delivery is bounded so a slow mail server cannot hold a job worker.
smtp = Rails.application.config.x.smtp
configured = %i[address username password from].all? { |key| smtp[key].to_s.strip.present? }

Rails.application.config.action_mailer.tap do |mailer|
  origin = URI(Concourse.app_url.presence || "http://localhost:3000")
  mailer.default_url_options = { host: origin.host, port: (origin.port unless origin.port == origin.default_port), protocol: origin.scheme }
  mailer.delivery_method = :test unless configured
  mailer.perform_deliveries = configured || Rails.env.test?
  mailer.raise_delivery_errors = true
  if configured
    mailer.delivery_method = :smtp
    mailer.smtp_settings = {
      address: smtp[:address].to_s, port: Integer(smtp[:port].to_s, 10, exception: false) || 587,
      user_name: smtp[:username].to_s, password: smtp[:password].to_s,
      authentication: :plain, enable_starttls_auto: true, open_timeout: 5, read_timeout: 10
    }
  end
end
