require "test_helper"

class Task::ContextTest < ActiveSupport::TestCase
  setup do
    @ajay = User.create!(ajent_sub: "1", handle: "ajay", email: "ajay@example.com", name: "Ajay", organizations: [ Organization.default ])
    @riley = User.create!(ajent_sub: "2", handle: "riley", email: "riley@example.com", name: "Riley", organizations: [ Organization.default ])
    @a = Agent.create!(owner: @ajay, handle: "codex", oauth_client_id: "client-a")
    @b = Agent.create!(owner: @riley, handle: "pi", oauth_client_id: "client-b")
    @c = Agent.create!(owner: @riley, handle: "fares", oauth_client_id: "client-c")
    @d = Agent.create!(owner: @riley, handle: "ci", oauth_client_id: "client-d")
  end

  test "two agents trading tasks are one flat conversation, however often they turn it round" do
    ask = open(@b, @a)
    answers = 3.times.map { open(@a, @b) }
    follow_up = open(@b, @a)

    context = thread
    assert_equal [ ask, *answers, follow_up ], context.children_of(nil)
    assert_empty context.children_of(ask)
  end

  test "a task that brings a new agent in nests under the task that brought its caller in" do
    ask = open(@b, @a)
    handoff = open(@c, @b)
    deeper = open(@d, @c)
    reply = open(@b, @c)
    answer = open(@a, @b)

    context = thread
    assert_equal [ ask, answer ], context.children_of(nil)
    assert_equal [ handoff, reply ], context.children_of(ask)
    assert_equal [ deeper ], context.children_of(handoff)
  end

  test "the thread's first caller starting a second conversation stays at the top" do
    ask = open(@b, @a)
    open(@a, @b)
    second = open(@c, @a)

    assert_equal [ ask, Task.find_by!(caller_agent: @b), second ], thread.children_of(nil)
  end

  test "a referenced task across conversations decides the nesting; a dangling or same-pair one does not" do
    ask = open(@b, @a)
    other = open(@c, @a)
    named = open(@d, @c, references: [ ask.id ])
    same_pair = open(@b, @a, references: [ other.id ])
    dangling = open(@d, @a, references: [ "7a9d0f79" ])

    context = thread
    assert_equal [ ask, other, same_pair, dangling ], context.children_of(nil)
    assert_equal [ named ], context.children_of(ask)
    assert_empty context.children_of(other)
  end

  test "the lead is the task waiting on the person, then the latest moving, then the latest settled" do
    done = open(@b, @a)
    done.transition_to!("TASK_STATE_COMPLETED", by: @b)
    moving = open(@b, @a)
    moving.transition_to!("TASK_STATE_WORKING", by: @b)
    assert_equal moving, thread.lead(@ajay)

    waiting = open(@a, @b)
    assert_equal waiting, thread.lead(@ajay)
    assert thread.awaiting?(@ajay)

    moving.transition_to!("TASK_STATE_COMPLETED", by: @b)
    travel 1.second
    waiting.transition_to!("TASK_STATE_COMPLETED", by: @a)
    assert_equal waiting, thread.lead(@ajay)
  end

  test "a page holds whole threads, latest activity first, with only what the scope can see" do
    old = open(@b, @a, context: "old")
    travel 1.minute
    open(@b, @a, context: "new")
    open(@c, @b, context: "new")
    hidden = open(@d, @c, context: "new")
    visible = Organization.default.tasks.involving_owner(@ajay).or(Organization.default.tasks.where(caller_agent: @b))

    page = Task::Context.page(visible, visible.unfinished, offset: 0, limit: 10)
    assert_equal [ "new", "old" ], page.map(&:id)
    assert_equal 2, page.first.tasks.size
    assert_not_includes page.first.tasks, hidden
    assert_equal [ old ], page.last.tasks

    assert_equal [ "old" ], Task::Context.page(visible, visible.unfinished, offset: 1, limit: 10).map(&:id)
  end

  private

  def open(recipient, caller, context: "ctx", references: [])
    travel 1.second
    Task.open!(recipient: recipient, caller: caller, context_id: context).tap do |task|
      Message.record!(task: task, role: "ROLE_USER", sender: caller, parts: [ { "text" => "hi" } ], reference_task_ids: references)
    end
  end

  def thread(id = "ctx")
    Task::Context.new(id, Organization.default.tasks.where(context_id: id).includes(:messages, caller_agent: :owner, recipient_agent: :owner).to_a)
  end
end
