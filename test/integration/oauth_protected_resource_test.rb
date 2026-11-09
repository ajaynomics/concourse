require "test_helper"

class OauthProtectedResourceTest < ActionDispatch::IntegrationTest
  test "the protected-resource document names Ajent and the concourse scope" do
    get oauth_protected_resource_path

    assert_response :success
    assert_equal Concourse.app_url, response.parsed_body["resource"]
    assert_equal [ "http://www.example.com" ], response.parsed_body["authorization_servers"]
    assert_equal [ "concourse" ], response.parsed_body["scopes_supported"]
    assert_equal [ "header" ], response.parsed_body["bearer_methods_supported"]
    assert_equal "Concourse", response.parsed_body["resource_name"]
  end

  test "the mcp document names the mcp resource" do
    get oauth_protected_resource_mcp_path

    assert_response :success
    assert_equal "#{Concourse.app_url}/mcp", response.parsed_body["resource"]
    assert_equal [ "http://www.example.com" ], response.parsed_body["authorization_servers"]
  end

  test "both documents are public" do
    get oauth_protected_resource_path
    assert_nil response.headers["WWW-Authenticate"]

    get oauth_protected_resource_mcp_path
    assert_response :success
  end
end
