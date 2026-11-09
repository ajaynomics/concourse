module TasksHelper
  # The board shows A2A's own state names, shortened only by dropping the
  # TASK_STATE_ prefix the wire format carries (§4.1.3).
  def state_label(state)
    t("tasks.states.#{state_key(state)}", default: state.to_s.delete_prefix("TASK_STATE_").tr("_", " ").capitalize)
  end

  def state_key(state)
    state.to_s.delete_prefix("TASK_STATE_").downcase
  end

  # The state's name as a word, never as a colour. Sky only when the task is
  # waiting on the signed-in person: sky means "your move" and nothing else.
  def state_badge(task_or_state, css: nil, move: nil)
    state = task_or_state.respond_to?(:state) ? task_or_state.state : task_or_state
    move = task_or_state.awaiting?(Current.user) if move.nil? && task_or_state.respond_to?(:awaiting?) && Current.user
    tag.span(state_label(state), class: class_names("state", css), data: { state: state, move: (true if move) })
  end

  # The lifeline: a task drawn as the line between its two agents. Where the
  # dot sits, and what closes the line, say the state; the state's name is
  # always printed beside it, so the glyph supports the word and never
  # replaces it. The dot's cx is an attribute a morph refresh updates in
  # place, so CSS moves it along the line when the state changes.
  LIFELINE_BALL = {
    "submitted" => 11, "working" => 53, "input_required" => 11, "auth_required" => 11
  }.freeze

  # A page may name each task's lifeline once: with a duplicate the browser
  # skips the whole view transition. A second drawing of a task on the same
  # page (a thread's summary, the marked row on the task's own page) passes
  # transition: false.
  def lifeline(task, css: "h-4 w-16", move: nil, transition: true)
    key = state_key(task.state)
    move = task.awaiting?(Current.user) if move.nil? && Current.user
    parts = [
      tag.path(d: key == "canceled" ? "M4 8h6M16 8h44" : "M4 8h56", class: "lifeline-line"),
      tag.path(d: "M4 3v10", class: "lifeline-end"),
      tag.path(d: "M60 3v10", class: "lifeline-end")
    ]
    parts << case key
    when "completed" then tag.path(d: "M57 3v10", class: "lifeline-end")
    when "failed" then tag.path(d: "M48 4l7 8M55 4l-7 8", class: "lifeline-end")
    when "rejected" then tag.path(d: "M54 3l-6 5 6 5", class: "lifeline-end")
    when "canceled" then tag.path(d: "M11 4l4 8", class: "lifeline-end")
    else
      tag.circle(cx: LIFELINE_BALL.fetch(key, 32), cy: 8, r: 3.5,
        class: class_names("lifeline-ball", "lifeline-ball-open": key == "submitted"))
    end
    parts << tag.path(d: "M8 12.5h6", class: "lifeline-end") if key == "auth_required"

    tag.svg(safe_join(parts), viewBox: "0 0 64 16", class: class_names("lifeline", css),
      data: { state: task.state, move: (true if move) }, "aria-hidden": "true",
      style: ("view-transition-name: lifeline-#{task.id}" if transition))
  end

  # The state as a sentence about the two agents, the way a person would
  # say it. Handles only: never message content.
  def state_sentence(task)
    caller_handle = task.caller_agent&.qualified_handle || t("agents.unnamed")
    recipient_handle = task.recipient_agent&.qualified_handle || t("agents.unnamed")
    t("tasks.sentences.#{state_key(task.state)}", caller: caller_handle, recipient: recipient_handle,
      default: state_label(task.state))
  end

  # The task's title for lists and its page: the caller's first line.
  # The page title uses the short id instead, so a tab or history entry
  # names the task without quoting it.
  def task_headline(task, css: nil)
    text = task.headline
    tag.span(text || t("tasks.untitled", id: short_id(task.id)), class: class_names(css, "text-ink-400": text.nil?))
  end

  def short_id(id)
    id.to_s.first(8)
  end

  def task_filter_link(key, current, count = nil)
    active = key == current
    link_to my_tasks_path(Current.organization, filter: (key unless key == "all")), class: "filter", aria: { current: ("page" if active) } do
      safe_join([ t("tasks.filters.#{key}"), (tag.span(count, class: "filter-count") if count) ].compact, " ")
    end
  end

  # One A2A Part (§5.6): text, data, or a file by url or raw bytes. Text is
  # formatted, data is shown as JSON, a file is named and never inlined.
  def render_part(part)
    part = part.to_h.stringify_keys
    if part["text"].present?
      tag.div(part["text"], class: "whitespace-pre-wrap text-pretty wrap-break-word [&+*]:mt-3")
    elsif part.key?("data")
      tag.pre(JSON.pretty_generate(part["data"]), class: "mt-2 overflow-x-auto rounded-xl bg-ink-950 p-3 font-mono text-xs leading-5 text-ink-200")
    elsif part["url"].present? || part["raw"].present?
      tag.div(class: "mt-2 flex items-center gap-2 text-sm") do
        safe_join([
          icon(:file, css: "size-4 text-ink-400"),
          tag.span(part["filename"].presence || t("tasks.show.file"), class: "truncate font-mono text-xs"),
          (tag.span(part["mediaType"], class: "ml-auto text-xs text-ink-400") if part["mediaType"].present?)
        ].compact)
      end
    end
  end
end
