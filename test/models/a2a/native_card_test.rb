require "test_helper"

class A2a::NativeCardTest < ActiveSupport::TestCase
  test "A2A 4.4.3 4.4.6 and 7.3 raw card has a matching native interface and arbitrary OAuth scheme name" do
    decoded = parse(card)
    assert decoded.streaming?
    assert_equal "0.1.0", decoded.revision
    assert_equal Digest::SHA256.hexdigest(JSON.generate(card)), decoded.digest
    assert_equal "Independent public name", decoded.card["name"]
    assert decoded.card.frozen?
    assert decoded.card["supportedInterfaces"].first.frozen?
    assert_not decoded.card.key?("metadata"), "no proprietary card identity required"
  end

  test "streaming is strictly boolean and optional false means GetTask polling" do
    [ false, :absent ].each do |value|
      body = card
      value == :absent ? body["capabilities"].delete("streaming") : body["capabilities"]["streaming"] = value
      assert_not parse(body).streaming?
    end
    [ nil, "true", 1 ].each do |value|
      body = card
      body["capabilities"]["streaming"] = value
      assert_raises(A2a::NativeCard::Invalid) { parse(body) }
    end
  end

  test "tenant is exact and cannot be inferred from card names or metadata" do
    body = card
    body["supportedInterfaces"].first["tenant"] = "native-tenant"
    assert parse(body, tenant: "native-tenant").streaming?
    assert_raises(A2a::NativeCard::Invalid) { parse(body) }
    assert_raises(A2a::NativeCard::Invalid) { parse(card, tenant: "native-tenant") }
    assert_raises(A2a::NativeCard::Invalid) { parse(body, tenant: "another-tenant") }
  end

  test "unsupported interface version endpoint and multiple interfaces fail closed" do
    { "protocolBinding" => "HTTP+JSON", "protocolVersion" => "0.3", "url" => "https://other.example/a2a" }.each do |key, value|
      body = card
      body["supportedInterfaces"].first[key] = value
      assert_raises(A2a::NativeCard::Invalid) { parse(body) }
    end
    body = card
    body["supportedInterfaces"] << body["supportedInterfaces"].first.dup
    assert_raises(A2a::NativeCard::Invalid) { parse(body) }
  end

  test "client credentials exact Ajent URLs and relay-only scopes match the single security requirement" do
    changes = [
      ->(body) { oauth(body)["oauth2MetadataUrl"] = "https://foreign.example/metadata" },
      ->(body) { flow(body)["tokenUrl"] = "https://foreign.example/token" },
      ->(body) { flow(body)["scopes"]["concourse"] = "User calls" },
      ->(body) { flow(body)["refreshUrl"] = "https://issuer.example/refresh" },
      ->(body) { oauth(body)["flows"]["authorizationCode"] = flow(body) },
      ->(body) { oauth(body)["flows"] = { "authorizationCode" => flow(body) } },
      ->(body) { body["securitySchemes"]["client"]["httpAuthSecurityScheme"] = { "scheme" => "Bearer" } },
      ->(body) { body["securitySchemes"]["other"] = body["securitySchemes"]["client"].dup },
      ->(body) { body["securityRequirements"] << { "schemes" => {} } },
      ->(body) { body["securityRequirements"].first["schemes"]["client"]["list"] = [ "concourse" ] },
      ->(body) { body["securityRequirements"] = [] }
    ]
    changes.each do |change|
      body = card
      change.call(body)
      assert_raises(A2a::NativeCard::Invalid) { parse(body) }
    end
    assert_raises(A2a::NativeCard::Invalid) { parse(card, token_url: "https://issuer.example/other") }
    assert_raises(A2a::NativeCard::Invalid) { parse(card, oauth2_metadata_url: "https://issuer.example/other") }
  end

  test "A2A 4.4.3 and 4.4.5 preserve truthful default and skill file output declarations" do
    %w[image/png application/pdf application/octet-stream text/markdown application/vnd.example+json].each do |mode|
      body = card
      body["defaultOutputModes"] = [ "text/plain", mode ]
      body["skills"] = [ skill.merge("outputModes" => [ mode ], "securityRequirements" => body["securityRequirements"].deep_dup) ]
      decoded = parse(body).card
      assert_equal [ "text/plain", mode ], decoded["defaultOutputModes"]
      assert_equal [ mode ], decoded["skills"].first["outputModes"]
      assert_equal body["securityRequirements"], decoded["skills"].first["securityRequirements"]
    end
  end

  test "default and skill inputs remain restricted to text and JSON" do
    %w[image/png application/pdf application/octet-stream].each do |mode|
      body = card
      body["defaultInputModes"] = [ mode ]
      assert_raises(A2a::NativeCard::Invalid) { parse(body) }
      body = card
      body["skills"] = [ skill.merge("inputModes" => [ mode ]) ]
      assert_raises(A2a::NativeCard::Invalid) { parse(body) }
    end
    body = card.merge("skills" => [ skill ])
    assert_equal %w[text/plain application/json], parse(body).card["skills"].first["inputModes"]
  end

  test "default and skill modes reject missing empty duplicated or non-array declarations" do
    %w[defaultInputModes defaultOutputModes inputModes outputModes].each do |key|
      [ [], [ "text/plain", "text/plain" ], nil, "text/plain" ].each do |modes|
        body = card
        if key.start_with?("default")
          body[key] = modes
        else
          body["skills"] = [ skill.merge(key => modes) ]
        end
        assert_raises(A2a::NativeCard::Invalid) { parse(body) }
      end
    end
  end

  test "default and skill outputs reject malformed non-concrete and oversized media types privately" do
    invalid = [ "", "image", "image/", "/png", "image /png", "image/png/extra", "image/png;private=value",
      "*/*", "image/*", "image/\npng", "image/png\u0000", "image/pnğ", "#{'x' * 128}/png", "image/#{'x' * 128}", nil, 1 ]
    invalid.each do |mode|
      [ :default, :skill ].each do |level|
        body = card
        if level == :default
          body["defaultOutputModes"] = [ mode ]
        else
          body["skills"] = [ skill.merge("outputModes" => [ mode ]) ]
        end
        error = assert_raises(A2a::NativeCard::Invalid) { parse(body) }
        assert_equal "invalid native card", error.message
        assert_nil error.cause
      end
    end
  end

  test "default and skill outputs bound declaration count and accept bounded type names" do
    modes = 64.times.map { |index| "application/x-output-#{index}" }
    modes[0] = "#{'x' * 127}/#{'y' * 127}"
    body = card.merge("defaultOutputModes" => modes, "skills" => [ skill.merge("outputModes" => modes) ])
    decoded = parse(body).card
    assert_equal modes, decoded["defaultOutputModes"]
    assert_equal modes, decoded["skills"].first["outputModes"]
    [ :default, :skill ].each do |level|
      body = card
      oversized = modes + [ "image/png" ]
      if level == :default
        body["defaultOutputModes"] = oversized
      else
        body["skills"] = [ skill.merge("outputModes" => oversized) ]
      end
      assert_raises(A2a::NativeCard::Invalid) { parse(body) }
    end
  end

  test "A2A 4.4.3 and 4.4.4 descriptive HTTPS links preserve query and fragment without fetching" do
    body = card.merge("documentationUrl" => "https://docs.example/agent#usage",
      "iconUrl" => "https://assets.example/icon.svg?v=1",
      "provider" => { "url" => "https://provider.example/?lang=en", "organization" => "Native provider" })
    assert_equal body, parse(body).card
    assert_not_requested :any, /https?:\/\//
  end

  test "descriptive URLs still reject unsafe malformed and unbounded links privately" do
    [ "http://docs.example/agent#usage", "javascript:private", "https://u:p@docs.example/agent?private=1",
      "https://docs.example:444/agent", "https://127.0.0.1/agent", "https://[::1]/agent", "https:///agent",
      "https://docs.example/has space", "https://docs.example/#{'x' * 2048}", nil ].each do |url|
      %w[documentationUrl iconUrl provider].each do |key|
        body = card
        body[key] = key == "provider" ? { "url" => url, "organization" => "Provider" } : url
        error = assert_raises(A2a::NativeCard::Invalid) { parse(body) }
        assert_equal "invalid native card", error.message
        assert_nil error.cause
      end
    end
    assert_not_requested :any, /https?:\/\//
  end

  test "actual endpoint resource and auth URLs keep HTTPS userinfo query and fragment restrictions" do
    [ "http://target.example/a2a", "https://u:p@target.example/a2a", "https://target.example/a2a?private=1",
      "https://target.example/a2a#private", "https://target.example:444/a2a", "https://127.0.0.1/a2a" ].each do |url|
      %i[endpoint_url resource token_url oauth2_metadata_url].each do |key|
        body = card
        case key
        when :endpoint_url then body["supportedInterfaces"].first["url"] = url
        when :token_url then flow(body)["tokenUrl"] = url
        when :oauth2_metadata_url then oauth(body)["oauth2MetadataUrl"] = url
        end
        error = assert_raises(A2a::NativeCard::Invalid) { parse(body, **{ key => url }) }
        assert_equal "invalid native card", error.message
        assert_nil error.cause
      end
    end
    assert_not_requested :any, /https?:\/\//
  end

  test "strict JSON bounded revision nesting and raw bytes never leak into errors" do
    invalid = [ "[]", "null", "{", '{"name":"private-body","name":"duplicate"}', '{"streaming":NaN}', "\xff".b,
      " " * (A2a::NativeCard::LIMIT + 1), "[" * 40 + "]" * 40 ]
    invalid.each do |body|
      error = assert_raises(A2a::NativeCard::Invalid) { parse(body) }
      assert_equal "invalid native card", error.message
      assert_nil error.cause
    end
    %w[version name].each do |key|
      body = card
      body[key] = "x" * 121
      assert_raises(A2a::NativeCard::Invalid) { parse(body) }
    end
    body = card.merge("metadata" => { "concourse.caller" => "spoof" })
    assert_raises(A2a::NativeCard::Invalid) { parse(body) }
    body = card
    body["capabilities"]["extensions"] = [ { "uri" => "urn:unknown", "required" => true } ]
    assert_raises(A2a::NativeCard::Invalid) { parse(body) }
  end

  private

  def parse(body, **options)
    body = JSON.generate(body) unless body.is_a?(String)
    A2a::NativeCard.parse(body, **{ endpoint_url: "https://native.example/a2a", resource: "https://native.example/a2a", tenant: nil,
      token_url: "https://issuer.example/oauth/token", oauth2_metadata_url: "https://issuer.example/.well-known/oauth-authorization-server" }.merge(options))
  end

  def card
    { "name" => "Independent public name", "description" => "A native agent", "version" => "0.1.0",
      "supportedInterfaces" => [ { "url" => "https://native.example/a2a", "protocolBinding" => "JSONRPC", "protocolVersion" => "1.0" } ],
      "capabilities" => { "streaming" => true, "pushNotifications" => false, "extendedAgentCard" => false },
      "defaultInputModes" => %w[text/plain application/json], "defaultOutputModes" => %w[text/plain application/json], "skills" => [],
      "securitySchemes" => { "client" => { "oauth2SecurityScheme" => { "oauth2MetadataUrl" => "https://issuer.example/.well-known/oauth-authorization-server",
        "flows" => { "clientCredentials" => { "tokenUrl" => "https://issuer.example/oauth/token", "scopes" => { "concourse:relay" => "Relay calls" } } } } } },
      "securityRequirements" => [ { "schemes" => { "client" => { "list" => [ "concourse:relay" ] } } } ] }
  end

  def skill
    { "id" => "answer", "name" => "Answer", "description" => "Answer locally", "tags" => [ "answer" ],
      "inputModes" => %w[text/plain application/json], "outputModes" => [ "application/json" ] }
  end

  def oauth(body)
    body["securitySchemes"]["client"]["oauth2SecurityScheme"]
  end

  def flow(body)
    oauth(body)["flows"]["clientCredentials"]
  end
end
