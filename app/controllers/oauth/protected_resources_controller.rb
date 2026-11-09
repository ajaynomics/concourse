class Oauth::ProtectedResourcesController < ActionController::API
  include NotAVisit
  def show
    render json: document(Concourse.app_url)
  end

  def mcp
    render json: document("#{Concourse.app_url}/mcp")
  end

  private

  def document(resource)
    {
      resource: resource,
      authorization_servers: [ Concourse.authorization_server ],
      scopes_supported: [ "concourse" ],
      bearer_methods_supported: [ "header" ],
      resource_name: "Concourse"
    }
  end
end
