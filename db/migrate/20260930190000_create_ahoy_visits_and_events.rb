# First-party visits and events for the owner-facing web pages, the same
# tables other Rails apps keep. Agent traffic (A2A, MCP, /api) never
# opens a visit; see config/initializers/ahoy.rb.
#
# No location columns: Concourse runs no geocoder, and a column nobody fills
# is a question nobody can answer. The owner foreign key nullifies, so
# analytics is never the reason an owner cannot be deleted.
class CreateAhoyVisitsAndEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :ahoy_visits do |t|
      t.string :visit_token
      t.string :visitor_token
      t.references :user, foreign_key: { to_table: :owners, on_delete: :nullify }

      t.string :ip
      t.text :user_agent
      t.text :referrer
      t.string :referring_domain
      t.text :landing_page

      t.string :browser
      t.string :os
      t.string :device_type
      t.boolean :bot, default: false, null: false

      t.string :utm_source
      t.string :utm_medium
      t.string :utm_term
      t.string :utm_content
      t.string :utm_campaign

      t.string :app_version
      t.string :os_version
      t.string :platform

      t.datetime :started_at
    end

    add_index :ahoy_visits, :visit_token, unique: true
    add_index :ahoy_visits, [ :visitor_token, :started_at ]

    create_table :ahoy_events do |t|
      t.references :visit, foreign_key: { to_table: :ahoy_visits, on_delete: :nullify }
      t.references :user, foreign_key: { to_table: :owners, on_delete: :nullify }

      t.string :name
      t.text :properties
      t.datetime :time
    end

    add_index :ahoy_events, [ :name, :time ]
  end
end
