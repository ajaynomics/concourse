require "test_helper"

class TaskTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(ajent_sub: "1", handle: "ajay", email: "ajay@example.com", name: "Ajay", organizations: [ Organization.default ])
    @other = User.create!(ajent_sub: "2", handle: "riley", email: "riley@example.com", name: "Riley", organizations: [ Organization.default ])
    @caller = Agent.create!(owner: @owner, handle: "codex", oauth_client_id: "client-a")
    @recipient = Agent.create!(owner: @other, handle: "pi", oauth_client_id: "client-b")
    @stranger = Agent.create!(owner: @owner, handle: "other", oauth_client_id: "client-c")
  end

  test "visible_to is the caller or the recipient and nobody else" do
    task = Task.open!(recipient: @recipient, caller: @caller, context_id: "ctx-1")
    hidden = Task.open!(recipient: @stranger, caller: @stranger)

    assert_equal [ task ], Task.visible_to(@caller).to_a
    assert_equal [ task ], Task.visible_to(@recipient).to_a
    assert_equal [ hidden ], Task.visible_to(@stranger).to_a
    assert_empty Task.visible_to(Agent.create!(owner: @other, oauth_client_id: "client-d"))
  end

  test "a task belongs to its recipient's organization and never spans two" do
    assert_equal Organization.default, Task.open!(recipient: @recipient, caller: @caller).organization

    elsewhere = Organization.create!(name: "Elsewhere")
    stranger = User.create!(ajent_sub: "3", handle: "sam", organizations: [ elsewhere ])
    outside = Agent.create!(owner: stranger, handle: "pi", oauth_client_id: "client-x")

    error = assert_raises(ActiveRecord::RecordInvalid) { Task.open!(recipient: outside, caller: @caller) }
    assert error.record.errors.added?(:base, :across_organizations)
    assert_raises(ActiveRecord::RecordInvalid) { Task.open!(recipient: @recipient, caller: outside) }
  end

  test "visible_to stays inside the agent's organization" do
    task = Task.open!(recipient: @recipient, caller: @caller)
    task.update_column(:organization_id, Organization.create!(name: "Elsewhere").id)

    assert_empty Task.visible_to(@caller)
  end

  test "a new task is submitted and keeps the context it was given" do
    task = Task.open!(recipient: @recipient, caller: @caller, context_id: "ctx-1")

    assert_equal "TASK_STATE_SUBMITTED", task.state
    assert_equal "ctx-1", task.context_id
    assert_match(/\A[0-9a-f-]{36}\z/, task.id)
  end

  test "the recipient may move a non-terminal task to any other stored state" do
    Task::STATES.without("TASK_STATE_SUBMITTED").each do |state|
      task = Task.open!(recipient: @recipient, caller: @caller)
      task.transition_to!(state, by: @recipient)
      assert_equal state, task.reload.state
    end
  end

  test "the caller cannot change state" do
    task = Task.open!(recipient: @recipient, caller: @caller)

    assert_raises(Task::NotRecipient) do
      task.transition_to!("TASK_STATE_WORKING", by: @caller)
    end
    assert_equal "TASK_STATE_SUBMITTED", task.reload.state
  end

  test "a terminal state is final" do
    task = Task.open!(recipient: @recipient, caller: @caller)
    task.transition_to!("TASK_STATE_COMPLETED", by: @recipient)

    assert task.terminal?
    assert_raises(Task::Terminal) do
      task.transition_to!("TASK_STATE_WORKING", by: @recipient)
    end
  end

  test "interrupted states are not terminal and can continue" do
    task = Task.open!(recipient: @recipient, caller: @caller)
    task.transition_to!("TASK_STATE_INPUT_REQUIRED", by: @recipient)

    assert task.interrupted?
    assert_not task.terminal?
    task.transition_to!("TASK_STATE_WORKING", by: @recipient)
    assert_equal "TASK_STATE_WORKING", task.state
  end

  test "an unknown state is refused" do
    task = Task.open!(recipient: @recipient, caller: @caller)

    assert_raises(Task::InvalidTransition) do
      task.transition_to!("TASK_STATE_UNSPECIFIED", by: @recipient)
    end
    assert_raises(Task::InvalidTransition) do
      task.transition_to!("completed", by: @recipient)
    end
  end

  test "staying in the same state is not a transition" do
    task = Task.open!(recipient: @recipient, caller: @caller)

    assert_raises(Task::InvalidTransition) do
      task.transition_to!("TASK_STATE_SUBMITTED", by: @recipient)
    end
  end

  test "agent messages and artifacts are the recipient's, and stop at a terminal state" do
    task = Task.open!(recipient: @recipient, caller: @caller)
    message = Message.record!(task: task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "hello" } ])
    artifact = Artifact.record!(task: task, by: @recipient, name: "note", parts: [ { "text" => "done" } ])

    assert_equal "ROLE_USER", message.role
    assert_equal message.message_id, message.id
    assert_equal artifact.artifact_id, artifact.id

    assert_raises(Task::NotRecipient) do
      Message.record!(task: task, role: "ROLE_AGENT", sender: @caller, parts: [ { "text" => "no" } ])
    end
    assert_raises(Task::NotCaller) do
      Message.record!(task: task, role: "ROLE_USER", sender: @recipient, parts: [ { "text" => "no" } ])
    end

    task.transition_to!("TASK_STATE_COMPLETED", by: @recipient)
    assert_raises(Task::Terminal) do
      Artifact.record!(task: task, by: @recipient, parts: [ { "text" => "late" } ])
    end
  end
end
