class Task::Context
  # A2A's contextId, the thread several tasks share, as one
  # viewer sees it: the tasks they can see in it, arranged as a tree. Not a
  # record; the scope it is built from decides what is in it.
  #
  # Two agents trading tasks in a thread are one conversation, listed flat in
  # the order it happened, whichever way each task went. A task that brings
  # a new agent in nests under the task that brought its caller in: B hands
  # part of A's ask to C. A message that names an earlier task in the thread
  # (referenceTaskIds, A2A §4.1.4 and §3.4.3) says where it nests instead.
  attr_reader :id, :tasks

  # One page of threads: those with a task in `matching`, latest activity
  # first, each holding every task of `visible` that shares its context.
  def self.page(visible, matching, offset:, limit:)
    ids = matching.group(:context_id)
      .order(Arel.sql("MAX(tasks.updated_at) DESC"), context_id: :desc)
      .offset(offset).limit(limit).pluck(:context_id)
    tasks = visible.where(context_id: ids)
      .includes(:messages, caller_agent: :owner, recipient_agent: :owner).to_a.group_by(&:context_id)
    ids.map { |id| new(id, tasks.fetch(id, [])) }
  end

  def initialize(id, tasks)
    @id = id
    @tasks = tasks.sort_by { |task| [ task.created_at, task.id ] }
    @children = arrange
  end

  def children_of(task)
    @children.fetch(task&.id, [])
  end

  def single?
    tasks.one?
  end

  def opener
    tasks.first
  end

  def updated_at
    tasks.map(&:updated_at).max
  end

  def agents
    tasks.flat_map { |task| [ task.caller_agent, task.recipient_agent ] }.uniq
  end

  def awaiting?(owner)
    tasks.any? { |task| task.awaiting?(owner) }
  end

  # The task that says where the thread stands: one waiting on this person,
  # else the latest still moving, else the latest to settle.
  def lead(owner)
    tasks.find { |task| task.awaiting?(owner) } ||
      tasks.reject(&:terminal?).max_by(&:status_at) ||
      tasks.max_by(&:status_at)
  end

  private

  def arrange
    parents = {}
    openers = {}
    brought_in = {}
    present = Set.new

    tasks.each do |task|
      pair = [ task.caller_agent_id, task.recipient_agent_id ].sort
      parents[task.id] =
        if (opener = openers[pair])
          parents[opener.id]
        else
          openers[pair] = task
          referenced(task, parents) || brought_in[task.caller_agent_id]&.id
        end
      brought_in[task.recipient_agent_id] ||= task unless present.include?(task.recipient_agent_id)
      present << task.caller_agent_id << task.recipient_agent_id
    end

    tasks.group_by { |task| parents[task.id] }
  end

  # An earlier task in this thread that the caller's messages name. A name
  # that is not here (another thread, or one this viewer cannot see) says
  # nothing about where the task sits.
  def referenced(task, placed)
    task.messages.select { |message| message.role == "ROLE_USER" }
      .flat_map { |message| Array(message.reference_task_ids) }
      .find { |id| placed.key?(id) }
  end
end
