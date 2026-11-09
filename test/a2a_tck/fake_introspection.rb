#!/usr/bin/env ruby
# frozen_string_literal: true

# Stand-in for Ajent's RFC 7662 endpoint. The app calls it with its normal
# introspection client; this is not a bypass inside the app. One token is
# active. Anything else is inactive, which the app rejects as 401.

require "base64"
require "json"
require "rackup/handler/falcon"

port = Integer(ENV.fetch("PORT"))
token = ENV.fetch("A2A_TCK_TOKEN")
client_id = ENV.fetch("INTROSPECTION__CLIENT_ID", "concourse-introspection")
client_secret = ENV.fetch("INTROSPECTION__CLIENT_SECRET", "test_introspection_secret")
audience = ENV.fetch("A2A_TCK_APP_URL").chomp("/")
subject = ENV.fetch("A2A_TCK_SUB", "tck-caller")
agent_client_id = ENV.fetch("A2A_TCK_CLIENT_ID", "tck-caller")
expected_basic = "Basic #{Base64.strict_encode64("#{client_id}:#{client_secret}")}"

app = lambda do |env|
  request = Rack::Request.new(env)
  unless request.post? && request.path == "/oauth/introspect"
    return [ 404, { "content-type" => "text/plain" }, [ "not found" ] ]
  end

  presented = request.get_header("HTTP_AUTHORIZATION").to_s
  unless presented.bytesize == expected_basic.bytesize && presented == expected_basic
    return [ 401, { "content-type" => "text/plain" }, [ "unauthorized" ] ]
  end

  presented_token = request.params["token"]
  body = if presented_token == token
    {
      "active" => true,
      "scope" => "concourse",
      "client_id" => agent_client_id,
      "sub" => subject,
      "aud" => audience,
      "exp" => Time.now.to_i + 3600,
      "email" => "tck-caller@example.com"
    }
  else
    { "active" => false }
  end
  [ 200, { "content-type" => "application/json" }, [ JSON.generate(body) ] ]
end

File.write(ENV["FAKE_PIDFILE"], Process.pid.to_s) if ENV["FAKE_PIDFILE"]
Rackup::Handler::Falcon.run(app, Host: "127.0.0.1", Port: port)
