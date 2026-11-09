require "test_helper"

class FilterParameterLoggingTest < ActiveSupport::TestCase
  test "message and artifact content is filtered" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      parts: [ { text: "secret words" } ],
      message: "hello",
      text: "body",
      raw: "bytes",
      data: { note: "no" }
    )

    assert_equal "[FILTERED]", filtered[:parts]
    assert_equal "[FILTERED]", filtered[:message]
    assert_equal "[FILTERED]", filtered[:text]
    assert_equal "[FILTERED]", filtered[:raw]
    assert_equal "[FILTERED]", filtered[:data]
  end

  test "connect codes, PKCE verifiers and client secrets are filtered, but not challenges" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("code" => "c", "code_verifier" => "v", "client_secret" => "s", "code_challenge" => "public")

    assert_equal [ "[FILTERED]" ] * 3, filtered.values_at("code", "code_verifier", "client_secret")
    assert_equal "public", filtered["code_challenge"]
  end
end
