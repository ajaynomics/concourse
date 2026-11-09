class ApplicationMailer < ActionMailer::Base
  default from: -> { Rails.application.config.x.smtp[:from] }
  layout false
end
