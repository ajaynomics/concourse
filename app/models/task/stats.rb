class Task::Stats
  def initialize(organization:, owner:, from:, before:)
    @organization = organization
    @tasks = organization.tasks.involving_owner(owner).where(created_at: ...before)
    @from, @before = from, before
  end

  def message_counts
    rows = read(<<~SQL).to_a
      WITH #{visible_tasks}, observed AS (
        SELECT substr(m.created_at, 1, 10) AS day, m.sender_agent_id,
               CASE WHEN t.execution_route = 'inbox' THEN (
                 SELECT e.state FROM task_events e
                 WHERE e.task_id = t.id AND e.state IS NOT NULL AND e.settlement_evidence = 1
                   AND e.created_at <= m.created_at
                 ORDER BY e.id DESC LIMIT 1
               ) END AS state
        FROM visible_tasks t JOIN messages m ON m.task_id = t.id
        WHERE m.created_at >= :from AND m.created_at < :before
      )
      SELECT day, sender_agent_id, state, COUNT(*) AS count
      FROM observed GROUP BY day, sender_agent_id, state
    SQL
    agents = @organization.agents.where(id: rows.pluck("sender_agent_id").uniq).includes(:owner, :namespace).index_by(&:id)
    rows.each { |row| row["agent"] = agents[row.delete("sender_agent_id")]&.qualified_handle }
    rows.sort_by { |row| row.values_at("day", "agent", "state").map(&:to_s) }
  end

  def summary
    read(<<~SQL).first
      WITH #{visible_tasks}, #{status_changes}, #{first_replies}
      SELECT
        (SELECT COUNT(*) FROM (
          SELECT task_id FROM changes WHERE state = 'TASK_STATE_INPUT_REQUIRED'
          GROUP BY task_id HAVING COUNT(*) > 4
        )) AS repeated_input,
        (SELECT COUNT(*) FROM completions) AS completed,
        (SELECT COUNT(*) FROM completions c WHERE NOT (#{completion_text})) AS completed_without_text,
        COUNT(*) AS first_reply_measured,
        (SELECT COUNT(*) FROM submitted) - COUNT(*) AS first_reply_missing,
        AVG(CASE WHEN position IN ((total + 1) / 2, (total + 2) / 2) THEN milliseconds END) AS first_reply_median_ms,
        MAX(CASE WHEN position = (95 * total + 99) / 100 THEN milliseconds END) AS first_reply_p95_ms
      FROM ranked_replies
    SQL
  end

  private

  def visible_tasks
    "visible_tasks AS (#{@tasks.select(:id, :recipient_agent_id, :execution_route, :created_at).to_sql})"
  end

  # The previous status can predate the range. A restatement or a caller-input
  # event is not a new entry into INPUT_REQUIRED (A2A §3.2.2).
  def status_changes
    <<~SQL
      changes AS (
        SELECT e.id, e.task_id, e.state, e.status_message_id, e.kind, e.payload, t.recipient_agent_id,
               prior.id AS previous_id, prior.status_message_id AS previous_message_id
        FROM visible_tasks t JOIN task_events e ON e.task_id = t.id
        JOIN task_events prior ON prior.id = (
          SELECT p.id FROM task_events p WHERE p.task_id = e.task_id AND p.id < e.id
            AND p.state IS NOT NULL AND p.settlement_evidence = 1 AND p.created_at < :before
          ORDER BY p.id DESC LIMIT 1
        )
        WHERE t.execution_route = 'inbox' AND e.settlement_evidence = 1 AND e.state != prior.state
          AND e.created_at >= :from AND e.created_at < :before
      ), completions AS (
        SELECT * FROM changes WHERE state = 'TASK_STATE_COMPLETED'
      )
    SQL
  end

  # The completion's new status message, never retained text from an older
  # state. For artifacts use the exact fenced reply list if present, otherwise
  # the recorded output interval used by A2a::Serializer.current_output.
  def completion_text
    <<~SQL
      EXISTS (
        SELECT 1 FROM messages m, json_each(m.parts) part
        WHERE m.task_id = c.task_id AND m.message_id = c.status_message_id
          AND m.message_id IS NOT c.previous_message_id AND m.role = 'ROLE_AGENT'
          AND m.sender_agent_id = c.recipient_agent_id AND #{text_part}
      ) OR EXISTS (
        SELECT 1 FROM task_events e JOIN artifacts a ON a.artifact_id = e.artifact_id AND a.task_id = e.task_id,
          json_each(a.parts) part
        WHERE e.task_id = c.task_id AND e.id < c.id
          AND CASE WHEN c.kind = 'reply' THEN a.artifact_id IN (
            SELECT value FROM json_each(c.payload, '$."concourse.output".artifactIds')
          ) ELSE e.id > c.previous_id END
          AND #{text_part}
      )
    SQL
  end

  def text_part
    "CASE WHEN part.type = 'object' AND json_type(part.value, '$.text') = 'text' " \
      "THEN trim(part.value ->> '$.text', char(9,10,11,12,13,32)) != '' ELSE 0 END"
  end

  def first_replies
    <<~SQL
      submitted AS (
        SELECT t.id, t.recipient_agent_id, e.created_at AS submitted_at
        FROM visible_tasks t LEFT JOIN task_events e ON e.id = (
          SELECT first.id FROM task_events first
          WHERE first.task_id = t.id AND first.state IS NOT NULL AND first.settlement_evidence = 1
          ORDER BY first.id LIMIT 1
        ) AND e.state = 'TASK_STATE_SUBMITTED' AND e.created_at >= :from AND e.created_at < :before
        WHERE t.execution_route = 'inbox' AND t.created_at >= :from
      ), replies AS (
        SELECT s.submitted_at, MIN(m.created_at) AS first_reply_at
        FROM submitted s JOIN messages m ON m.task_id = s.id AND m.role = 'ROLE_AGENT'
          AND m.sender_agent_id = s.recipient_agent_id AND m.created_at >= s.submitted_at AND m.created_at < :before
        GROUP BY s.id, s.submitted_at
      ), timings AS (
        SELECT ROUND(1000 * (unixepoch(first_reply_at, 'subsec') - unixepoch(submitted_at, 'subsec'))) AS milliseconds
        FROM replies
      ), ranked_replies AS (
        SELECT milliseconds, ROW_NUMBER() OVER (ORDER BY milliseconds) AS position, COUNT(*) OVER () AS total
        FROM timings
      )
    SQL
  end

  def read(sql)
    Task.with_connection do |connection|
      connection.select_all(Task.sanitize_sql_array([ sql, { from: @from, before: @before } ]), "Task statistics")
    end
  end
end
