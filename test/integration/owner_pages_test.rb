require "test_helper"

class OwnerPagesTest < ActionDispatch::IntegrationTest
  setup do
    @ajay = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay", organizations: [ Organization.default ])
    @riley = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", name: "Riley", organizations: [ Organization.default ])
    @stan = User.create!(ajent_sub: "9", handle: "stan", email: "stan@example.com", name: "Stan", organizations: [ Organization.default ])
    @codex = Agent.create!(owner: @ajay, handle: "codex", oauth_client_id: "client-a")
    @pi = Agent.create!(owner: @riley, handle: "pi", oauth_client_id: "client-b")
    @hermes = Agent.create!(owner: @stan, handle: "hermes", oauth_client_id: "client-c")
  end

  test "a task page shows the thread" do
    task = Task.open!(recipient: @pi, caller: @codex)
    Message.record!(task: task, role: "ROLE_USER", sender: @codex, parts: [ { "text" => "Can you review accounts?" } ])
    task.transition_to!("TASK_STATE_INPUT_REQUIRED", by: @pi)

    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")
    get my_task_path(Organization.default, task)

    assert_response :success
    assert_select "ol.thread li", text: /Can you review accounts\?/
    assert_select ".state[data-state=TASK_STATE_INPUT_REQUIRED]"
  end

  test "a task none of my agents sent or received is not found" do
    task = Task.open!(recipient: @hermes, caller: @pi)

    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")
    get my_task_path(Organization.default, task)

    assert_response :not_found
  end

  test "needs you lists work waiting on my agents and nothing else" do
    inbound = Task.open!(recipient: @codex, caller: @pi)
    paused = Task.open!(recipient: @pi, caller: @codex)
    paused.transition_to!("TASK_STATE_INPUT_REQUIRED", by: @pi)
    moving = Task.open!(recipient: @pi, caller: @codex)
    moving.transition_to!("TASK_STATE_WORKING", by: @pi)

    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")
    get my_tasks_path(Organization.default, filter: "needs_you")

    assert_response :success
    assert_select "#tasks_board a[href='#{my_task_path(Organization.default, inbound)}']"
    assert_select "#tasks_board a[href='#{my_task_path(Organization.default, paused)}']"
    assert_select "#tasks_board a[href='#{my_task_path(Organization.default, moving)}']", count: 0
  end

  test "tasks list by thread: one task is a row, several fold under the first" do
    ask = Task.open!(recipient: @pi, caller: @codex, context_id: "accounts")
    Message.record!(task: ask, role: "ROLE_USER", sender: @codex, parts: [ { "text" => "Reship the Denver order" } ])
    answer = Task.open!(recipient: @codex, caller: @pi, context_id: "accounts")
    handoff = Task.open!(recipient: @hermes, caller: @pi, context_id: "accounts")
    unseen = Task.open!(recipient: @hermes, caller: @hermes, context_id: "accounts")
    alone = Task.open!(recipient: @pi, caller: @codex, context_id: "alone")

    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")
    get my_tasks_path(Organization.default)

    assert_response :success
    assert_select "#tasks_board details[open]", count: 1 do
      assert_select "summary", text: /Reship the Denver order.*2 tasks/m
      assert_select ".thread-tree a[href='#{my_task_path(Organization.default, ask)}']"
      assert_select ".thread-tree a[href='#{my_task_path(Organization.default, answer)}']"
    end
    assert_select "#tasks_board a[href='#{my_task_path(Organization.default, handoff)}']", count: 0
    assert_select "#tasks_board a[href='#{my_task_path(Organization.default, unseen)}']", count: 0
    assert_select "##{dom_id(alone, :thread)} > a[href='#{my_task_path(Organization.default, alone)}']"
  end

  test "a filter picks threads and keeps them whole" do
    done = Task.open!(recipient: @pi, caller: @codex, context_id: "mixed")
    done.transition_to!("TASK_STATE_COMPLETED", by: @pi)
    moving = Task.open!(recipient: @codex, caller: @pi, context_id: "mixed")
    moving.transition_to!("TASK_STATE_WORKING", by: @codex)
    finished = Task.open!(recipient: @pi, caller: @codex, context_id: "finished")
    finished.transition_to!("TASK_STATE_COMPLETED", by: @pi)

    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")
    get my_tasks_path(Organization.default, filter: "open")

    assert_select "#tasks_board a[href='#{my_task_path(Organization.default, done)}']"
    assert_select "#tasks_board a[href='#{my_task_path(Organization.default, moving)}']"
    assert_select "#tasks_board a[href='#{my_task_path(Organization.default, finished)}']", count: 0
    assert_select "a.filter[aria-current=page] .filter-count", text: "1"
  end

  test "a task page shows its thread with the task marked" do
    ask = Task.open!(recipient: @pi, caller: @codex, context_id: "accounts")
    handoff = Task.open!(recipient: @hermes, caller: @pi, context_id: "accounts")
    answer = Task.open!(recipient: @codex, caller: @pi, context_id: "accounts")

    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")
    get my_task_path(Organization.default, answer)

    assert_select "#thread_title .count", text: "2"
    assert_select "a.row[aria-current=page][href='#{my_task_path(Organization.default, answer)}']"
    assert_select "a.row[href='#{my_task_path(Organization.default, ask)}']"
    assert_select "a.row[href='#{my_task_path(Organization.default, handoff)}']", count: 0

    get my_task_path(Organization.default, Task.open!(recipient: @pi, caller: @codex))
    assert_select "#thread_title", count: 0
  end

  test "every view-transition name on a threaded page is unique, or the browser skips the transition" do
    ask = Task.open!(recipient: @pi, caller: @codex, context_id: "accounts")
    answer = Task.open!(recipient: @codex, caller: @pi, context_id: "accounts")
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")

    [ my_tasks_path(Organization.default), my_task_path(Organization.default, ask), my_task_path(Organization.default, answer) ].each do |path|
      get path
      names = css_select("[style*='view-transition-name']").map { |node| node["style"][/view-transition-name:\s*([^;]+)/, 1].strip }
      assert names.any?, path
      assert_equal names.uniq, names, path
    end
  end

  test "the board counts and lists my agents' work" do
    Task.open!(recipient: @codex, caller: @pi)

    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")
    get organization_root_path(Organization.default)

    assert_response :success
    assert_select "#awaiting_title"
    assert_select "turbo-cable-stream-source"
  end

  test "the app is installable" do
    get pwa_manifest_path(format: :json)
    assert_response :success
    assert_equal "Concourse", response.parsed_body["name"]
    assert_equal "#f6f2ef", response.parsed_body["theme_color"]
    assert response.parsed_body["icons"].any? { |icon| icon["purpose"] == "maskable" }
    assert_equal %w[narrow wide], response.parsed_body["screenshots"].map { |shot| shot["form_factor"] }
    images = response.parsed_body.values_at("icons", "screenshots").flatten.map { |image| image["src"] }
    images.each { |src| assert Rails.public_path.join(src.delete_prefix("/")).file?, src }

    get pwa_service_worker_path(format: :js)
    assert_response :success
    assert_includes response.body, "/offline.html"
  end

  test "analytics know who and where: handle, name, email, agents, full IP, and location" do
    get sign_in_path, headers: { "CF-IPCountry" => "CA", "CF-IPCity" => "Toronto", "CF-Region" => "Ontario" },
      env: { "REMOTE_ADDR" => "203.0.113.42" }
    visit = Ahoy::Visit.last
    assert_equal "203.0.113.42", visit.ip
    assert_equal [ "CA", "Ontario", "Toronto" ], [ visit.country, visit.region, visit.city ]

    sign_in_via_ajent
    body = Nokogiri::HTML(response.body).at("body")
    assert_equal "ajay", body["data-analytics-user-id-value"]
    traits = JSON.parse(body["data-analytics-traits-value"])
    assert_equal({ "handle" => "ajay", "name" => "Ajay Krishnan", "email" => "ajay@example.com",
      "organization" => "concourse", "agents" => [ "ajay/codex" ] }, traits.except("user_id"))
  end

  test "a page view records the organization it was seen in" do
    sign_in_via_ajent

    post "/ahoy/events", params: { events: [ { name: "$view", properties: { page: "/" }, time: Time.current.to_f } ] }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "Ahoy-Visit" => cookies["ahoy_visit"], "Ahoy-Visitor" => cookies["ahoy_visitor"] }

    assert_equal "concourse", Ahoy::Event.where_event("$view", page: "/").sole.properties["organization"]
  end

  test "a person's page view opens a visit and an agent's call does not" do
    assert_difference -> { Ahoy::Visit.count }, 1 do
      get sign_in_path, headers: { "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15" }
    end

    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42")
      assert_no_difference -> { Ahoy::Visit.count } do
        get "/agents", headers: { "Authorization" => "Bearer token-a" }
        get api_tasks_path, headers: { "Authorization" => "Bearer token-a" }
      end
    end
  end
end
