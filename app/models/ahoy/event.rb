# One named thing that happened on a page, with a JSON bag of properties.
# Properties name routes and states, never message or artifact content.
#
# `properties` is text with a JSON coder because SQLite has no jsonb; query it
# through Ahoy's helpers, which compile to JSON_EXTRACT:
#
#   Ahoy::Event.where_event("$view", page: "/tasks")
class Ahoy::Event < ApplicationRecord
  include Ahoy::QueryMethods

  self.table_name = "ahoy_events"

  belongs_to :visit, class_name: "Ahoy::Visit", optional: true
  belongs_to :user, optional: true

  serialize :properties, coder: JSON

  # Page views grouped by route shape: ids become :id, so the summary
  # counts pages, not individual tasks.
  UUID = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/

  def self.views_by_page(since:)
    where(name: "$view", time: since..).joins(:visit).merge(Ahoy::Visit.human)
      .pluck(:properties)
      .map { |properties| properties.to_h["page"].to_s.gsub(UUID, ":id").presence || "(unknown)" }
      .tally.sort_by { |page, count| [ -count, page ] }
  end
end
