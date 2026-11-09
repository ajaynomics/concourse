module JoinsHelper
  TAGS = %w[h1 h2 h3 h4 h5 p br ul ol li strong em code pre a blockquote table thead tbody tr th td hr].freeze

  # JOIN.md, sanitized, with an id on each h2 so the contents can link to it.
  # The ids are added after sanitizing and derived from the heading's own
  # text; the second sanitize admits id and nothing else new.
  def join_document
    @join_document ||= begin
      guide = Concourse.v3? ? "JOIN-V3.md" : "JOIN.md"
      fragment = Nokogiri::HTML5.fragment(guide_markdown(Rails.root.join(guide).read))
      sections = fragment.css("h2").map do |heading|
        heading["id"] = "section-#{heading.text.parameterize}"
        [ heading["id"], heading.text ]
      end
      { html: sanitize(fragment.to_html, tags: TAGS, attributes: %w[href id]), sections: sections }
    end
  end

  def join_html
    join_document[:html]
  end

  # An organization's own note, written by its owners, read the same way.
  def guide_note_html(organization)
    guide_markdown(organization.guide_note) if organization&.guide_note.present?
  end

  def join_sections
    join_document[:sections]
  end

  private

  # hardbreaks off: commonmarker-rb turns every source newline into <br> by
  # default, and the guide is wrapped for reading as text.
  def guide_markdown(text)
    html = Commonmarker.to_html(text, options: { render: { unsafe: false, hardbreaks: false } })
    sanitize(html, tags: TAGS, attributes: %w[href])
  end
end
