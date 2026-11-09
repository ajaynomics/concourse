require "test_helper"
require_relative "../support/push_hosts"

class PushConfigApiTest < ActionDispatch::IntegrationTest
  include PushHosts

  TOKEN = "push-token-0123456789abcdef"

  setup do
    stub_push_hosts
    owner = User.create!(handle: "hooked", ajent_sub: "push-hooked", organizations: [ Organization.default ])
    @agent = Agent.create!(owner: owner, handle: "assistant", oauth_client_id: "client-assistant")
    stub_agent_token("assistant", client_id: @agent.oauth_client_id, sub: owner.ajent_sub)
  end

  teardown { restore_push_hosts }

  test "needs an agent bearer" do
    get api_push_config_path
    assert_response :unauthorized
  end

  test "put, replace, get and delete without ever returning the token" do
    get api_push_config_path, headers: headers
    assert_response :not_found

    put_config(url: PushHosts::HOOK, token: TOKEN)
    assert_response :success
    assert_equal %w[updated_at url], response.parsed_body.keys.sort
    assert_equal PushHosts::HOOK, response.parsed_body["url"]
    assert_not_includes response.body, TOKEN
    assert_not_includes @agent.push_config.token_before_type_cast, TOKEN, "stored encrypted"

    put_config(url: "#{PushHosts::HOOK}/v2", token: "rotated-token-0123456789")
    assert_response :success
    assert_equal 1, PushConfig.where(agent: @agent).count
    assert_equal "rotated-token-0123456789", @agent.reload.push_config.token

    get api_push_config_path, headers: headers
    assert_response :success
    assert_equal "#{PushHosts::HOOK}/v2", response.parsed_body["url"]
    assert_not_includes response.body, "rotated-token"

    delete api_push_config_path, headers: headers
    assert_response :no_content
    assert_nil @agent.reload.push_config
    delete api_push_config_path, headers: headers
    assert_response :no_content
  end

  test "refuses non-HTTPS, private, unresolvable URLs and bad tokens" do
    [
      { url: "http://hooks.example.com/concourse", token: TOKEN },
      { url: "https://internal.example.com/hook", token: TOKEN },
      { url: "https://loopback.example.com/hook", token: TOKEN },
      { url: "https://10.0.0.5/hook", token: TOKEN },
      { url: "https://unknown.example.com/hook", token: TOKEN },
      { url: PushHosts::HOOK, token: "short" },
      { url: PushHosts::HOOK, token: "has a space in it ok" },
      { url: PushHosts::HOOK }
    ].each do |body|
      put_config(**body)
      assert_response :unprocessable_entity, body[:url]
      assert_not_includes response.body, TOKEN
    end
    assert_nil @agent.reload.push_config
  end

  private

  def headers
    { "Authorization" => "Bearer assistant", "CONTENT_TYPE" => "application/json" }
  end

  def put_config(**body)
    put api_push_config_path, params: body.to_json, headers: headers
  end
end
