Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root "organization_redirects#show"

  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  get "sign_in", to: "sessions#new", as: :sign_in
  post "auth/ajent", as: :ajent_auth, to: ->(_env) { [ 404, {}, [] ] }
  get "auth/ajent/callback", to: "sessions#create"
  get "auth/failure", to: "sessions#failure"
  delete "sign_out", to: "sessions#destroy", as: :sign_out

  get "/.well-known/oauth-protected-resource", to: "oauth/protected_resources#show", as: :oauth_protected_resource
  get "/.well-known/oauth-protected-resource/mcp", to: "oauth/protected_resources#mcp", as: :oauth_protected_resource_mcp
  # What an agent reads first: the guide, and the llms.txt index of it and the
  # machine documents. Fixed paths, ahead of the organization pages.
  get "auth.md", to: "agent_guides#show", format: false, defaults: { format: :md }, as: :agent_guide
  get "llms.txt", to: "agent_guides#index", format: false, defaults: { format: :md }, as: :agent_guides
  # MCP Server Card (SEP-2127): <streamable-http-url>/server-card.
  get "mcp/server-card", to: "mcp_server_cards#show", format: false, as: :mcp_server_card

  get "join", to: "joins#show", as: :join
  # A web app makes an agent with one approval: consent here, then a code
  # exchange (RFC 6749 §4.1 with PKCE). Ajent mints the credential.
  resource :connect, only: %i[show create destroy]
  namespace :connect do
    resource :token, only: :create
    resource :revocation, only: :create, path: "revoke"
  end
  namespace :developer do
    resource :setup, only: %i[show create]
  end
  get "terms", to: "terms#show", as: :terms
  get "privacy", to: "privacy#show", as: :privacy
  get "sitemap.xml", to: "sitemaps#show", defaults: { format: :xml }, as: :sitemap

  get "api/identity", to: "api/identities#show", as: :api_identity
  get "api/me", to: "api/me#show", as: :api_me
  # The agent's event log: what its peers did, in order, with a server-side cursor.
  get "api/events", to: "api/events#index", as: :api_events
  put "api/events/cursor", to: "api/event_cursors#update", as: :api_events_cursor
  # The agent's own webhook, told (without content) when an event arrives.
  get "api/push_config", to: "api/push_configs#show", as: :api_push_config
  put "api/push_config", to: "api/push_configs#update"
  delete "api/push_config", to: "api/push_configs#destroy"
  # The Pi extension's token audience is the app URL, not /mcp. These routes
  # run the same A2a::Exchange operations as the MCP tools and JSON-RPC.
  patch "api/card", to: "api/cards#update", as: :api_card
  get "api/tasks", to: "api/tasks#index", as: :api_tasks
  get "api/tasks/:id", to: "api/tasks#show", as: :api_task
  get "api/next_task", to: "api/next_task#show", as: :api_next_task
  get "api/doorbell", to: "api/doorbells#show", as: :api_doorbell
  get "api/projects", to: "api/projects#index", as: :api_projects
  # An owner's own signed-in agent acting for them: the web's approve, decline
  # and retire (Agent::OwnerAuthority). :id is the numeric agent id.
  namespace :api do
    resources :pending_agents, only: %i[index destroy]
    resources :agents, only: [] do
      scope module: :agents do
        resource :approval, only: :create
        resource :retirement, only: :create
      end
    end
  end

  # Bearer requests are agents. A session request is the HTML directory.
  # The numeric inbox route is ahead of the handle route: /agents/1/tasks
  # would otherwise be owner "1", agent "tasks".
  get "agents/:agent_id/tasks", to: "worker/inboxes#show", constraints: { agent_id: /\d+/ }, as: :worker_inbox
  get "agents", to: "api/agents#index", as: nil, constraints: ->(request) { request.authorization.to_s.start_with?("Bearer ") }

  resource :push_subscription, only: %i[create destroy]
  resources :organizations, only: %i[new create]

  # An agent's address names its organization. The shorter address from
  # before organizations still answers, with no redirect, because agents
  # hold it in their configuration: its card is the default organization's
  # agent, and a call reaches the caller's own organization.
  scope "/a2a(/:organization_slug)/:owner_handle/:agent_handle" do
    get ".well-known/agent-card", to: "a2a/cards#show", defaults: { format: :json }
    post "/", to: "a2a/rpc#create"
  end

  post "tasks/:task_id/messages", to: "worker/tasks#create_message", as: :worker_task_messages
  patch "tasks/:task_id", to: "worker/tasks#update", as: :worker_task
  post "tasks/:task_id/artifacts", to: "worker/tasks#create_artifact", as: :worker_task_artifacts

  post "mcp", to: "mcp#create"
  get "mcp", to: "mcp#show"
  delete "mcp", to: "mcp#destroy"

  # Pages from before organizations were in the address. Each goes to the
  # same page in the organization that holds it.
  get "agents", to: "organization_redirects#show", as: nil
  get "agents/:owner_handle/:handle(/edit)", to: "organization_redirects#agent", as: nil
  get "tasks", to: "organization_redirects#show", as: nil
  get "tasks/:id", to: "organization_redirects#task", as: nil
  get "organization/edit", to: "organization_redirects#show", as: nil

  # A person's pages are under the organization they are about. Last, so a
  # fixed path above always wins; Organization reserves those words.
  scope ":organization_slug" do
    get "/", to: "home#show", as: :organization_root
    get "agents", to: "agents#index", as: :agents
    get "agents/:owner_handle/:handle", to: "agents#show", as: :agent
    get "agents/:owner_handle/:handle/edit", to: "agents#edit", as: :edit_agent
    patch "agents/:owner_handle/:handle", to: "agents#update"
    scope "agents/:owner_handle/:handle" do
      resource :native_endpoint, only: %i[show create update destroy], controller: "agents/native_endpoints"
      resource :retirement, only: %i[show create], controller: "agents/retirements"
    end
    get "tasks", to: "owner_tasks#index", as: :my_tasks
    get "tasks/:id", to: "owner_tasks#show", as: :my_task
    # The owner acting as their own agent on its task. Not the worker routes
    # above: those are an agent's bearer requests, these are a person's session.
    post "tasks/:task_id/response", to: "owner_tasks/responses#create", as: :my_task_response
    post "tasks/:task_id/cancellation", to: "owner_tasks/cancellations#create", as: :my_task_cancellation
    resources :projects, only: %i[index new create edit update destroy], param: :slug
    resource :organization, only: %i[edit update]
    # Owners only: whether each agent's mail is being answered and read.
    resource :mail_health, only: :show, path: "health"
    resources :memberships, only: :destroy
    resources :namespaces, only: %i[create destroy], param: :name
    resources :removals, only: :destroy
    resources :invitations, only: %i[create destroy]
    resources :join_requests, only: :destroy do
      resource :approval, only: :create, module: :join_requests
    end
    resources :pending_agents, only: :destroy do
      resource :approval, only: :create, module: :pending_agents
    end
  end
end
