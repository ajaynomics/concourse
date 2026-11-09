# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.2].define(version: 2026_11_08_150000) do
  create_table "agent_client_bindings", force: :cascade do |t|
    t.string "client_id", null: false
    t.integer "agent_id"
    t.integer "bound_owner_id", null: false
    t.integer "bound_organization_id", null: false
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "provenance", default: "operator", null: false
    t.index ["agent_id"], name: "index_agent_client_bindings_on_agent_id", unique: true
    t.index ["client_id"], name: "index_agent_client_bindings_on_client_id", unique: true
  end

  create_table "agent_connections", id: :string, force: :cascade do |t|
    t.integer "organization_id", null: false
    t.integer "agent_id", null: false
    t.integer "membership_id", null: false
    t.string "session_id", limit: 200, null: false
    t.datetime "observed_at", null: false
    t.datetime "lease_expires_at", null: false
    t.datetime "limit_at", null: false
    t.datetime "closed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "session_id"], name: "index_agent_connections_on_agent_id_and_session_id"
    t.index ["agent_id"], name: "index_agent_connections_on_agent_id"
    t.index ["organization_id", "agent_id", "closed_at", "lease_expires_at"], name: "index_connections_on_live_lease"
    t.index ["organization_id", "agent_id", "observed_at"], name: "index_connections_on_recent_observation"
    t.index ["organization_id"], name: "index_agent_connections_on_organization_id"
  end

  create_table "agent_events", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "task_id", limit: 36, null: false
    t.integer "seq", null: false
    t.string "kind", null: false
    t.string "message_id"
    t.string "artifact_id"
    t.string "state"
    t.datetime "created_at", null: false
    t.index ["agent_id", "seq"], name: "index_agent_events_on_agent_id_and_seq", unique: true
    t.index ["task_id"], name: "index_agent_events_on_task_id"
  end

  create_table "agents", force: :cascade do |t|
    t.integer "owner_id", null: false
    t.string "handle"
    t.string "name"
    t.text "description"
    t.json "skills", default: [], null: false
    t.string "harness"
    t.string "oauth_client_id"
    t.datetime "last_seen_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "organization_id", null: false
    t.string "native_endpoint_url"
    t.string "native_card_url"
    t.string "native_resource"
    t.string "native_tenant"
    t.integer "native_generation", default: 0, null: false
    t.boolean "native_enabled", default: false, null: false
    t.boolean "native_discoverable", default: false, null: false
    t.datetime "native_verified_at"
    t.json "native_verification", default: {}, null: false
    t.json "native_card", default: {}, null: false
    t.string "native_card_revision", limit: 120
    t.integer "namespace_id"
    t.datetime "admitted_at"
    t.datetime "declined_at"
    t.integer "event_seq", default: 0, null: false
    t.integer "event_cursor", default: 0, null: false
    t.datetime "stuck_alerted_at"
    t.index ["namespace_id", "handle"], name: "index_agents_on_namespace_id_and_handle", unique: true
    t.index ["namespace_id"], name: "index_agents_on_namespace_id"
    t.index ["organization_id"], name: "index_agents_on_organization_id"
    t.index ["owner_id", "handle"], name: "index_agents_on_owner_id_and_handle", unique: true, where: "namespace_id IS NULL"
    t.index ["owner_id", "oauth_client_id"], name: "index_agents_on_owner_id_and_oauth_client_id", unique: true
    t.index ["owner_id"], name: "index_agents_on_owner_id"
  end

  create_table "ahoy_events", force: :cascade do |t|
    t.integer "visit_id"
    t.integer "user_id"
    t.string "name"
    t.text "properties"
    t.datetime "time"
    t.index ["name", "time"], name: "index_ahoy_events_on_name_and_time"
    t.index ["user_id"], name: "index_ahoy_events_on_user_id"
    t.index ["visit_id"], name: "index_ahoy_events_on_visit_id"
  end

  create_table "ahoy_visits", force: :cascade do |t|
    t.string "visit_token"
    t.string "visitor_token"
    t.integer "user_id"
    t.string "ip"
    t.text "user_agent"
    t.text "referrer"
    t.string "referring_domain"
    t.text "landing_page"
    t.string "browser"
    t.string "os"
    t.string "device_type"
    t.boolean "bot", default: false, null: false
    t.string "utm_source"
    t.string "utm_medium"
    t.string "utm_term"
    t.string "utm_content"
    t.string "utm_campaign"
    t.string "app_version"
    t.string "os_version"
    t.string "platform"
    t.datetime "started_at"
    t.string "country"
    t.string "region"
    t.string "city"
    t.float "latitude"
    t.float "longitude"
    t.index ["user_id"], name: "index_ahoy_visits_on_user_id"
    t.index ["visit_token"], name: "index_ahoy_visits_on_visit_token", unique: true
    t.index ["visitor_token", "started_at"], name: "index_ahoy_visits_on_visitor_token_and_started_at"
  end

  create_table "artifacts", primary_key: "artifact_id", id: { type: :string, limit: 36 }, force: :cascade do |t|
    t.string "task_id", null: false
    t.string "name"
    t.text "description"
    t.json "parts", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "native_artifact_id"
    t.json "metadata", default: {}, null: false
    t.json "extensions", default: [], null: false
    t.integer "native_position"
    t.index ["task_id", "native_artifact_id"], name: "index_artifacts_on_task_id_and_native_artifact_id", unique: true
    t.index ["task_id"], name: "index_artifacts_on_task_id"
  end

  create_table "connect_grants", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "code_digest", null: false
    t.string "code_challenge", null: false
    t.string "redirect_uri", null: false
    t.string "client_id", null: false
    t.text "client_secret"
    t.datetime "expires_at", null: false
    t.datetime "used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_connect_grants_on_agent_id"
    t.index ["code_digest"], name: "index_connect_grants_on_code_digest", unique: true
  end

  create_table "invitations", force: :cascade do |t|
    t.integer "organization_id", null: false
    t.string "email", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "email"], name: "index_invitations_on_organization_id_and_email", unique: true
    t.index ["organization_id"], name: "index_invitations_on_organization_id"
  end

  create_table "join_requests", force: :cascade do |t|
    t.integer "organization_id", null: false
    t.integer "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "user_id"], name: "index_join_requests_on_organization_id_and_user_id", unique: true
    t.index ["organization_id"], name: "index_join_requests_on_organization_id"
    t.index ["user_id"], name: "index_join_requests_on_user_id"
  end

  create_table "memberships", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "organization_id", null: false
    t.string "role", default: "member", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_memberships_on_organization_id"
    t.index ["user_id", "organization_id"], name: "index_memberships_on_user_id_and_organization_id", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "messages", primary_key: "message_id", id: { type: :string, limit: 36 }, force: :cascade do |t|
    t.string "task_id", null: false
    t.string "role", null: false
    t.integer "sender_agent_id", null: false
    t.json "parts", null: false
    t.json "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.json "extensions", default: [], null: false
    t.json "reference_task_ids", default: [], null: false
    t.string "client_message_id"
    t.string "native_message_id"
    t.string "native_task_id"
    t.string "native_context_id"
    t.integer "native_after_sequence"
    t.integer "native_position"
    t.index ["sender_agent_id", "client_message_id"], name: "index_messages_on_sender_and_client_message_id", unique: true
    t.index ["sender_agent_id"], name: "index_messages_on_sender_agent_id"
    t.index ["task_id", "role", "native_message_id"], name: "index_messages_on_task_id_and_role_and_native_message_id", unique: true
    t.index ["task_id"], name: "index_messages_on_task_id"
  end

  create_table "namespaces", force: :cascade do |t|
    t.integer "organization_id", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_namespaces_on_name", unique: true
    t.index ["organization_id"], name: "index_namespaces_on_organization_id"
  end

  create_table "organizations", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.text "email_domains"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "guide_note"
    t.string "admission", default: "automatic", null: false
    t.boolean "machine_clients", default: false, null: false
    t.index ["slug"], name: "index_organizations_on_slug", unique: true
  end

  create_table "participations", force: :cascade do |t|
    t.integer "project_id", null: false
    t.integer "agent_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_participations_on_agent_id"
    t.index ["project_id", "agent_id"], name: "index_participations_on_project_id_and_agent_id", unique: true
  end

  create_table "projects", force: :cascade do |t|
    t.integer "organization_id", null: false
    t.string "slug", null: false
    t.string "name", null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "slug"], name: "index_projects_on_organization_id_and_slug", unique: true
    t.index ["organization_id"], name: "index_projects_on_organization_id"
  end

  create_table "push_configs", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "url", limit: 2048, null: false
    t.text "token", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "last_succeeded_at"
    t.datetime "last_failed_at"
    t.integer "consecutive_failures", default: 0, null: false
    t.index ["agent_id"], name: "index_push_configs_on_agent_id", unique: true
  end

  create_table "push_subscriptions", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "endpoint", null: false
    t.string "p256dh_key", null: false
    t.string "auth_key", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["endpoint"], name: "index_push_subscriptions_on_endpoint", unique: true
    t.index ["user_id"], name: "index_push_subscriptions_on_user_id"
  end

  create_table "relay_contexts", force: :cascade do |t|
    t.integer "organization_id", null: false
    t.integer "caller_agent_id", null: false
    t.integer "recipient_agent_id", null: false
    t.integer "generation", null: false
    t.string "public_context_id", null: false
    t.string "native_context_id"
    t.datetime "content_changed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["caller_agent_id"], name: "index_relay_contexts_on_caller_agent_id"
    t.index ["organization_id", "caller_agent_id", "recipient_agent_id", "generation", "native_context_id"], name: "index_relay_contexts_on_native_identity", unique: true
    t.index ["organization_id", "caller_agent_id", "recipient_agent_id", "generation", "public_context_id"], name: "index_relay_contexts_on_public_identity", unique: true
    t.index ["organization_id"], name: "index_relay_contexts_on_organization_id"
    t.index ["recipient_agent_id"], name: "index_relay_contexts_on_recipient_agent_id"
  end

  create_table "relay_deliveries", id: { type: :string, limit: 36 }, force: :cascade do |t|
    t.integer "organization_id", null: false
    t.integer "caller_agent_id", null: false
    t.integer "recipient_agent_id", null: false
    t.string "task_id"
    t.string "reserved_task_id", null: false
    t.string "public_task_id"
    t.string "operation", null: false
    t.string "message_id_digest", null: false
    t.string "request_digest", null: false
    t.json "request_payload"
    t.json "result_payload"
    t.string "execution_route", null: false
    t.string "endpoint_url"
    t.string "resource"
    t.string "tenant"
    t.integer "generation", default: 0, null: false
    t.string "phase", default: "reserved", null: false
    t.string "outcome"
    t.string "holder"
    t.integer "fence", default: 0, null: false
    t.datetime "deadline_at"
    t.datetime "content_changed_at", null: false
    t.datetime "expired_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "after_sequence", default: 0, null: false
    t.boolean "native_streaming", default: false, null: false
    t.index ["caller_agent_id", "message_id_digest"], name: "index_relay_deliveries_on_caller_and_message_digest", unique: true
    t.index ["caller_agent_id"], name: "index_relay_deliveries_on_caller_agent_id"
    t.index ["content_changed_at"], name: "index_relay_deliveries_on_content_changed_at"
    t.index ["organization_id"], name: "index_relay_deliveries_on_organization_id"
    t.index ["phase", "deadline_at"], name: "index_relay_deliveries_on_phase_and_deadline_at"
    t.index ["recipient_agent_id"], name: "index_relay_deliveries_on_recipient_agent_id"
    t.index ["task_id"], name: "index_relay_deliveries_on_active_mutation", unique: true, where: "task_id IS NOT NULL AND phase IN ('reserved', 'sending')"
    t.index ["task_id"], name: "index_relay_deliveries_on_task_id"
    t.check_constraint "execution_route IN ('inbox', 'native')", name: "relay_deliveries_execution_route"
    t.check_constraint "phase IN ('reserved', 'sending', 'held', 'accepted', 'rejected')", name: "relay_deliveries_phase"
  end

  create_table "relay_network_slots", force: :cascade do |t|
    t.string "kind", null: false
    t.integer "organization_id"
    t.string "holder"
    t.datetime "expires_at"
    t.index ["kind", "organization_id", "expires_at"], name: "idx_on_kind_organization_id_expires_at_c4c5d0905a"
    t.index ["organization_id"], name: "index_relay_network_slots_on_organization_id"
    t.check_constraint "kind IN ('dispatch', 'follow')", name: "relay_slot_kind"
  end

  create_table "relay_tasks", force: :cascade do |t|
    t.string "task_id", null: false
    t.integer "organization_id", null: false
    t.integer "caller_agent_id", null: false
    t.integer "recipient_agent_id", null: false
    t.string "endpoint_url", null: false
    t.string "resource", null: false
    t.string "tenant"
    t.integer "generation", null: false
    t.string "native_task_id", null: false
    t.string "native_context_id"
    t.json "upstream_metadata", default: {}, null: false
    t.datetime "upstream_status_at"
    t.datetime "observed_at"
    t.datetime "changed_at"
    t.string "snapshot_digest"
    t.datetime "next_follow_at"
    t.string "lease_holder"
    t.datetime "lease_expires_at"
    t.integer "fence", default: 0, null: false
    t.boolean "stale", default: false, null: false
    t.boolean "gap", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "follow_failures", default: 0, null: false
    t.boolean "auth_paused", default: false, null: false
    t.boolean "budget_exhausted", default: false, null: false
    t.boolean "native_streaming", default: false, null: false
    t.index ["caller_agent_id"], name: "index_relay_tasks_on_caller_agent_id"
    t.index ["next_follow_at"], name: "index_relay_tasks_on_next_follow_at"
    t.index ["organization_id", "recipient_agent_id", "generation", "native_task_id"], name: "index_relay_tasks_on_native_identity", unique: true
    t.index ["organization_id"], name: "index_relay_tasks_on_organization_id"
    t.index ["recipient_agent_id"], name: "index_relay_tasks_on_recipient_agent_id"
    t.index ["task_id"], name: "index_relay_tasks_on_task_id", unique: true
  end

  create_table "removals", force: :cascade do |t|
    t.integer "organization_id", null: false
    t.integer "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "user_id"], name: "index_removals_on_organization_id_and_user_id", unique: true
    t.index ["organization_id"], name: "index_removals_on_organization_id"
    t.index ["user_id"], name: "index_removals_on_user_id"
  end

  create_table "task_deliveries", id: :string, force: :cascade do |t|
    t.integer "organization_id", null: false
    t.string "task_id", null: false
    t.string "connection_id", null: false
    t.string "session_id", null: false
    t.string "phase", default: "queued", null: false
    t.json "message_ids", default: [], null: false
    t.string "settlement_digest"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["connection_id"], name: "index_task_deliveries_on_connection_id"
    t.index ["organization_id"], name: "index_task_deliveries_on_organization_id"
    t.index ["task_id"], name: "index_task_deliveries_on_task_id"
    t.index ["task_id"], name: "index_task_deliveries_on_unfinished_task", unique: true, where: "phase IN ('queued', 'prompting', 'running', 'uncertain')"
    t.check_constraint "phase IN ('queued', 'prompting', 'running', 'uncertain', 'settled', 'canceled')", name: "task_deliveries_phase"
  end

  create_table "task_delivery_messages", force: :cascade do |t|
    t.string "task_delivery_id", null: false
    t.string "message_id", null: false
    t.index ["message_id"], name: "index_task_delivery_messages_on_message_id", unique: true
    t.index ["task_delivery_id"], name: "index_task_delivery_messages_on_task_delivery_id"
  end

  create_table "task_events", force: :cascade do |t|
    t.string "task_id", limit: 36, null: false
    t.string "state"
    t.string "status_message_id"
    t.string "artifact_id"
    t.datetime "created_at", null: false
    t.string "kind"
    t.json "payload"
    t.string "upstream_timestamp"
    t.boolean "settlement_evidence", default: true, null: false
    t.index ["task_id", "id"], name: "index_task_events_on_task_id_and_id"
  end

  create_table "tasks", id: { type: :string, limit: 36 }, force: :cascade do |t|
    t.integer "recipient_agent_id", null: false
    t.integer "caller_agent_id", null: false
    t.string "context_id", null: false
    t.string "state", default: "TASK_STATE_SUBMITTED", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "status_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "status_message_id"
    t.integer "organization_id", null: false
    t.string "execution_route", default: "inbox", null: false
    t.datetime "content_changed_at"
    t.index ["caller_agent_id"], name: "index_tasks_on_caller_agent_id"
    t.index ["context_id"], name: "index_tasks_on_context_id"
    t.index ["execution_route", "content_changed_at"], name: "index_tasks_on_execution_route_and_content_changed_at"
    t.index ["organization_id"], name: "index_tasks_on_organization_id"
    t.index ["recipient_agent_id"], name: "index_tasks_on_recipient_agent_id"
    t.index ["state"], name: "index_tasks_on_state"
    t.index ["status_at", "id"], name: "index_tasks_on_status_at_and_id"
    t.check_constraint "execution_route IN ('inbox', 'native', 'held')", name: "tasks_execution_route"
  end

  create_table "users", force: :cascade do |t|
    t.string "ajent_sub"
    t.string "handle", null: false
    t.string "email"
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "email_verified", default: false, null: false
    t.index ["ajent_sub"], name: "index_users_on_ajent_sub", unique: true
    t.index ["handle"], name: "index_users_on_handle", unique: true
  end

  add_foreign_key "agent_client_bindings", "agents", on_delete: :nullify
  add_foreign_key "agent_connections", "agents", on_delete: :cascade
  add_foreign_key "agent_connections", "organizations"
  add_foreign_key "agent_events", "agents", on_delete: :cascade
  add_foreign_key "agent_events", "tasks", on_delete: :cascade
  add_foreign_key "agents", "namespaces"
  add_foreign_key "agents", "organizations"
  add_foreign_key "agents", "users", column: "owner_id"
  add_foreign_key "ahoy_events", "ahoy_visits", column: "visit_id", on_delete: :nullify
  add_foreign_key "ahoy_events", "users", on_delete: :nullify
  add_foreign_key "ahoy_visits", "users", on_delete: :nullify
  add_foreign_key "artifacts", "tasks"
  add_foreign_key "connect_grants", "agents", on_delete: :cascade
  add_foreign_key "invitations", "organizations"
  add_foreign_key "join_requests", "organizations"
  add_foreign_key "join_requests", "users"
  add_foreign_key "memberships", "organizations"
  add_foreign_key "memberships", "users"
  add_foreign_key "messages", "agents", column: "sender_agent_id"
  add_foreign_key "messages", "tasks"
  add_foreign_key "namespaces", "organizations"
  add_foreign_key "participations", "agents", on_delete: :cascade
  add_foreign_key "participations", "projects", on_delete: :cascade
  add_foreign_key "projects", "organizations"
  add_foreign_key "push_configs", "agents", on_delete: :cascade
  add_foreign_key "push_subscriptions", "users", on_delete: :cascade
  add_foreign_key "relay_contexts", "agents", column: "caller_agent_id"
  add_foreign_key "relay_contexts", "agents", column: "recipient_agent_id"
  add_foreign_key "relay_contexts", "organizations"
  add_foreign_key "relay_deliveries", "agents", column: "caller_agent_id"
  add_foreign_key "relay_deliveries", "agents", column: "recipient_agent_id"
  add_foreign_key "relay_deliveries", "organizations"
  add_foreign_key "relay_deliveries", "tasks", on_delete: :nullify
  add_foreign_key "relay_network_slots", "organizations", on_delete: :nullify
  add_foreign_key "relay_tasks", "agents", column: "caller_agent_id"
  add_foreign_key "relay_tasks", "agents", column: "recipient_agent_id"
  add_foreign_key "relay_tasks", "organizations"
  add_foreign_key "relay_tasks", "tasks", on_delete: :cascade
  add_foreign_key "removals", "organizations"
  add_foreign_key "removals", "users"
  add_foreign_key "task_deliveries", "agent_connections", column: "connection_id"
  add_foreign_key "task_deliveries", "organizations"
  add_foreign_key "task_deliveries", "tasks", on_delete: :cascade
  add_foreign_key "task_delivery_messages", "messages", primary_key: "message_id", on_delete: :cascade
  add_foreign_key "task_delivery_messages", "task_deliveries", on_delete: :cascade
  add_foreign_key "task_events", "tasks", on_delete: :cascade
  add_foreign_key "tasks", "agents", column: "caller_agent_id"
  add_foreign_key "tasks", "agents", column: "recipient_agent_id"
  add_foreign_key "tasks", "organizations"
end
