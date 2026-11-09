module ApplicationHelper
  # Who Rybbit sees: the person by handle, with their name, email,
  # organization, and agents as traits. Blank means anonymous, and the
  # analytics controller clears the identity instead.
  def analytics_user_id
    Current.user&.handle.to_s
  end

  def analytics_traits
    user = Current.user
    return {} unless user

    { user_id: user.id, handle: user.handle, name: user.name, email: user.email,
      organization: Current.organization&.slug, agents: user.agents.map(&:qualified_handle) }.compact
  end

  def analytics_site_id
    Concourse.config(:analytics, :site_id)
  end

  def nav_link(label, path, active: current_page?(path), **options)
    link_to label, path, class: class_names("nav-link", options.delete(:class)), aria: { current: ("page" if active) }, **options
  end

  def tab_link(label, path, icon_name, active: current_page?(path))
    link_to path, class: "tab", aria: { current: ("page" if active) } do
      safe_join([ icon(icon_name), tag.span(label) ])
    end
  end

  def section_active?(prefix)
    request.path == prefix || request.path.start_with?("#{prefix}/")
  end

  # prefix/agent. The agent's own name leads; the prefix is quieter.
  def agent_handle(agent, link: true, mine: false, css: nil)
    return tag.span(t("agents.unnamed"), class: class_names("handle text-ink-400", css)) if agent.nil? || agent.unnamed?

    label = safe_join([
      tag.span("#{agent.prefix}/", class: "handle-owner"),
      tag.span(agent.handle, class: "handle-name")
    ])
    css = class_names("handle", css, "handle-mine": mine)
    return tag.span(label, class: css) unless link

    link_to label, agent_path(Current.organization, agent.prefix, agent.handle), class: class_names(css, "link-quiet")
  end

  # A shared view-transition-name lets Turbo fly an agent's handle from its
  # card into the agent page's heading. Each agent appears once per page.
  def agent_transition_name(agent)
    "agent-#{agent.id}"
  end

  def mine?(agent)
    Current.user.present? && agent&.owner_id == Current.user.id
  end

  def ago(time)
    return tag.span("—", class: "text-ink-500") if time.blank?

    tag.time(t("time.ago", time: time_ago_in_words(time)), datetime: time.iso8601, title: l(time, format: :long))
  end

  # Presence, said plainly. last_seen_at moves when Ajent introspects the
  # agent's token, so it means "made an authenticated call", nothing more.
  def agent_presence(agent)
    return t("agents.never_called") if agent.last_seen_at.blank?
    return t("agents.active_now") if agent.recently_seen?

    t("agents.last_call", time: waited(agent.last_seen_at))
  end

  # How long something has waited, the short way: "4 min", "3 h", "2 d".
  def waited(since)
    return "" if since.blank?

    seconds = (Time.current - since).to_i
    if seconds < 60 then t("time.short.now")
    elsif seconds < 3600 then t("time.short.minutes", count: seconds / 60)
    elsif seconds < 86_400 then t("time.short.hours", count: seconds / 3600)
    else t("time.short.days", count: seconds / 86_400)
    end
  end

  # A time on a list: HH:MM today, the date before that. The server writes
  # its own zone; local_time_controller rewrites it in the reader's.
  def board_time(time)
    text = time.to_date == Date.current ? time.strftime("%H:%M") : time.strftime("%b %-d")
    tag.time(text, datetime: time.iso8601, title: l(time, format: :long),
      class: "font-mono tabular-nums", data: { controller: "local-time" })
  end

  # A small, fixed icon set, inline so it inherits currentColor and costs no
  # request. Paths are 24×24, stroke 1.75.
  ICONS = {
    board: '<path d="M5 12l-2 0l9 -9l9 9l-2 0"/><path d="M5 12v7a2 2 0 0 0 2 2h10a2 2 0 0 0 2 -2v-7"/><path d="M9 21v-6a2 2 0 0 1 2 -2h2a2 2 0 0 1 2 2v6"/>',
    agents: '<path d="M5 7a4 4 0 1 0 8 0a4 4 0 1 0 -8 0"/><path d="M3 21v-2a4 4 0 0 1 4 -4h4a4 4 0 0 1 4 4v2"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/><path d="M21 21v-2a4 4 0 0 0 -3 -3.85"/>',
    tasks: '<path d="M13 5h8"/><path d="M13 9h5"/><path d="M13 15h8"/><path d="M13 19h5"/><path d="M3 5a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v4a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1l0 -4"/><path d="M3 15a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v4a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1l0 -4"/>',
    guide: '<path d="M3 19a9 9 0 0 1 9 0a9 9 0 0 1 9 0"/><path d="M3 6a9 9 0 0 1 9 0a9 9 0 0 1 9 0"/><path d="M3 6l0 13"/><path d="M12 6l0 13"/><path d="M21 6l0 13"/>',
    copy: '<path d="M7 9.667a2.667 2.667 0 0 1 2.667 -2.667h8.666a2.667 2.667 0 0 1 2.667 2.667v8.666a2.667 2.667 0 0 1 -2.667 2.667h-8.666a2.667 2.667 0 0 1 -2.667 -2.667l0 -8.666"/><path d="M4.012 16.737a2.005 2.005 0 0 1 -1.012 -1.737v-10c0 -1.1 .9 -2 2 -2h10c.75 0 1.158 .385 1.5 1"/>',
    check: '<path d="M5 12l5 5l10 -10"/>',
    chevron: '<path d="M9 6l6 6l-6 6"/>',
    arrow: '<path d="M5 12l14 0"/><path d="M13 18l6 -6"/><path d="M13 6l6 6"/>',
    back: '<path d="M5 12l14 0"/><path d="M5 12l6 6"/><path d="M5 12l6 -6"/>',
    search: '<path d="M3 10a7 7 0 1 0 14 0a7 7 0 1 0 -14 0"/><path d="M21 21l-6 -6"/>',
    external: '<path d="M12 6h-6a2 2 0 0 0 -2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2 -2v-6"/><path d="M11 13l9 -9"/><path d="M15 4h5v5"/>',
    signout: '<path d="M14 8v-2a2 2 0 0 0 -2 -2h-7a2 2 0 0 0 -2 2v12a2 2 0 0 0 2 2h7a2 2 0 0 0 2 -2v-2"/><path d="M9 12h12l-3 -3"/><path d="M18 15l3 -3"/>',
    file: '<path d="M14 3v4a1 1 0 0 0 1 1h4"/><path d="M17 21h-10a2 2 0 0 1 -2 -2v-14a2 2 0 0 1 2 -2h7l5 5v11a2 2 0 0 1 -2 2"/><path d="M9 9l1 0"/><path d="M9 13l6 0"/><path d="M9 17l6 0"/>',
    close: '<path d="M18 6l-12 12"/><path d="M6 6l12 12"/>',
    edit: '<path d="M4 20h4l10.5 -10.5a2.828 2.828 0 1 0 -4 -4l-10.5 10.5v4"/><path d="M13.5 6.5l4 4"/>',
    bell: '<path d="M10 5a2 2 0 1 1 4 0a7 7 0 0 1 4 6v3a4 4 0 0 0 2 3h-16a4 4 0 0 0 2 -3v-3a7 7 0 0 1 4 -6"/><path d="M9 17v1a3 3 0 0 0 6 0v-1"/>',
    install: '<path d="M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2 -2v-2"/><path d="M7 11l5 5l5 -5"/><path d="M12 4l0 12"/>',
    switch: '<path d="M7 3l-4 4l4 4"/><path d="M3 7h11"/><path d="M17 13l4 4l-4 4"/><path d="M21 17h-11"/>',
    settings: '<path d="M4 6h8"/><path d="M16 6h4"/><path d="M4 12h2"/><path d="M10 12h10"/><path d="M4 18h11"/><path d="M19 18h1"/><path d="M12 4v4"/><path d="M6 10v4"/><path d="M15 16v4"/>',
    plus: '<path d="M12 5l0 14"/><path d="M5 12l14 0"/>'
  }.freeze

  def icon(name, css: "size-5")
    tag.svg(ICONS.fetch(name).html_safe, class: css, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor",
      "stroke-width": "1.75", "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true")
  end

  # The mark is the lifeline: two agents, the line between them, and the
  # task travelling along it. Same drawing as public/icon.svg, without the tile.
  def brand_mark(css: "h-6 w-10")
    tag.svg(class: css, viewBox: "0 0 40 24", fill: "none", "aria-hidden": "true") do
      safe_join([
        tag.path(d: "M5 12h30", stroke: "currentColor", "stroke-width": "2", "stroke-linecap": "round"),
        tag.path(d: "M5 6v12M35 6v12", stroke: "currentColor", "stroke-width": "2", "stroke-linecap": "round"),
        tag.circle(cx: "22", cy: "12", r: "4.5", fill: "#359cf4")
      ])
    end
  end
end
