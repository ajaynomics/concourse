require "test_helper"

# Scope through associations, never default_scope, which leaks through
# unscoped, joins, and jobs that run without a Current. A convention alone
# will not hold; this test is the enforcement.
#
# It fails on any bare `Model.find` / `find_by` / `where` / `named` / ...
# against a tenant-owned model in a controller, job, model, tool, or helper.
# Those go through an organization (Current.organization, the calling
# agent's, or the default one for public reads), or through a record already
# inside one, so an id or handle from another organization is not found.
#
# A genuinely global query opts out with a reason on the same line:
#
#   Task.where(updated_at: ...) # tenancy-ok: retention applies to every organization
class TenancyScopingTest < ActiveSupport::TestCase
  # Records that carry organization_id, plus Organization itself.
  TENANT_MODELS = %w[
    Organization
    Membership
    Namespace
    Removal
    JoinRequest
    Invitation
    Agent
    Agent::Connection
    Task
    TaskDelivery
    Project
    RelayDelivery
    RelayTask
    RelayContext
    RelayNetworkSlot
  ].freeze

  # Unleased capacity slots have no tenant; leased slots belong to the acquiring
  # organization. They remain in the query scan rather than escaping as globals.
  NULLABLE_TENANT_POOLS = %w[RelayNetworkSlot].freeze

  # No organization_id of their own: they belong to a task, and a task to one
  # organization. Scanned all the same, since reaching one is reaching its
  # task's organization.
  REACHED_THROUGH_TASK = %w[
    Message
    Artifact
    TaskEvent
    AgentEvent
    TaskDeliveryMessage
  ].freeze

  # No organization_id of their own: a participation joins an agent to a
  # project, both in the project's organization.
  REACHED_THROUGH_PROJECT = %w[
    Participation
  ].freeze

  # No organization_id of their own: an agent's push config and /connect
  # grants are its agent's.
  REACHED_THROUGH_AGENT = %w[
    PushConfig
    ConnectGrant
  ].freeze

  # A person is one account across every organization they belong to, and so
  # are the browsers they get alerts on. Visits and page views begin before
  # anyone signs in; Ahoy::Store puts the organization on each event instead.
  # Client-ID reservations survive tenant/agent deletion; they expose no tenant
  # data until the bound agent passes membership and organization admission.
  GLOBAL_MODELS = %w[
    User
    Agent::ClientBinding
    PushSubscription
    Ahoy::Visit
    Ahoy::Event
  ].freeze

  TENANT_JOBS = %w[
    ApprovalAlertJob
    OwnerAlertJob
    PushNotificationJob
    RelayFollowJob
    RevokeAgentClientJob
  ].freeze

  GLOBAL_SWEEPS = %w[
    PurgeExpiredTasksJob
    RelaySweepJob
    StuckMailAlertJob
  ].freeze

  UNSCOPED_CALLS = %w[
    find find_by find_by! where all first last count exists? named
    find_or_create_by find_or_create_by! find_or_initialize_by
    sole take pluck select find_signed update_all delete_all destroy_all
  ].freeze

  SCANNED_GLOBS = [
    "app/controllers/**/*.rb",
    "app/helpers/**/*.rb",
    "app/jobs/**/*.rb",
    "app/models/**/*.rb",
    "app/tools/**/*.rb"
  ].freeze

  OPT_OUT = /#\s*tenancy-ok:\s*\S/

  test "nothing reaches a tenant-owned model globally" do
    offenses = scan_for_offenses

    assert_empty offenses, <<~MESSAGE
      Unscoped access to tenant-owned models:

      #{offenses.join("\n")}

      Reach these through an organization or a record inside one. If the
      query is genuinely global, append "# tenancy-ok: <reason>" to the line.
    MESSAGE
  end

  test "no model declares default_scope" do
    offenders = Rails.root.glob("app/models/**/*.rb").select { |path| path.read.match?(/^\s*default_scope\b/) }

    assert_empty offenders.map(&:to_s), "default_scope leaks through unscoped, joins, and jobs; scope through associations"
  end

  test "every record is a tenant model, reached through a task or a project, or deliberately global" do
    Rails.application.eager_load!
    records = ApplicationRecord.descendants.reject { |klass| klass.abstract_class? || klass.name.blank? }
    with_org, without_org = records.partition { |klass| klass.column_names.include?("organization_id") }

    assert_equal TENANT_MODELS.sort, ([ "Organization" ] + with_org.map(&:name)).uniq.sort,
      "A record with organization_id belongs in TENANT_MODELS"
    assert_equal (REACHED_THROUGH_TASK + REACHED_THROUGH_PROJECT + REACHED_THROUGH_AGENT + GLOBAL_MODELS + [ "Organization" ]).sort, without_org.map(&:name).sort,
      "A new record without organization_id must say how it reaches an organization, or why it is global"

    with_org.each do |klass|
      next if NULLABLE_TENANT_POOLS.include?(klass.name)
      assert_not klass.columns_hash["organization_id"].null, "#{klass.name}.organization_id must be NOT NULL"
    end
  end

  test "the tables with organization_id are the tenant models' tables" do
    connection = ActiveRecord::Base.connection
    tables = connection.tables.select { |table| connection.columns(table).any? { |column| column.name == "organization_id" } }

    assert_equal (TENANT_MODELS - [ "Organization" ]).map { |name| name.constantize.table_name }.sort, tables.sort
  end

  test "every job is a tenant job or a named global sweep" do
    Rails.application.eager_load!

    assert_equal (TENANT_JOBS + GLOBAL_SWEEPS).sort, app_jobs.map(&:name).sort,
      "A new job takes organization_id first, or joins GLOBAL_SWEEPS and says why"
  end

  test "tenant jobs take organization_id first, so a worker without Current is still scoped" do
    TENANT_JOBS.each do |name|
      assert_equal "organization_id", required_perform_arguments(name.constantize).first, name
    end
  end

  test "global sweeps take no arguments and say they are deliberately global" do
    GLOBAL_SWEEPS.each do |name|
      job = name.constantize
      assert_empty required_perform_arguments(job), name
      assert_match(/deliberately global/i, Rails.root.join("app/jobs/#{name.underscore}.rb").read, name)
    end
  end

  test "the scan detects a violation" do
    assert_equal 1, offenses_in("app/controllers/fake_controller.rb", "    @agent = Agent.find(params[:id])\n").size
    assert_equal 1, offenses_in("app/models/fake.rb", "    Agent.named(owner, handle)\n").size
    assert_equal 1, offenses_in("app/models/fake.rb", "    Task.exists?(id)\n").size
    assert_equal 1, offenses_in("app/models/fake.rb", "    Message.find_by_task_id(id)\n").size
    assert_equal 1, offenses_in("app/models/fake.rb", "    Agent::Connection.where(active: true)\n").size
    assert_equal 1, offenses_in("app/models/fake.rb", "    TaskDelivery.find(id)\n").size
    assert_equal 1, offenses_in("app/models/fake.rb", "    TaskDeliveryMessage.find(id)\n").size
    assert_equal 1, offenses_in("app/models/fake.rb", "    Task.select(:id) # tenancy-ok:\n").size, "an opt-out needs a reason"

    assert_empty offenses_in("app/controllers/fake_controller.rb", "    Current.organization.agents.find(params[:id])\n")
    assert_empty offenses_in("app/models/fake.rb", "    Task.where(x: 1) # tenancy-ok: a reason\n")
    assert_empty offenses_in("app/models/fake.rb", "    # Agent.find(id) in a comment\n")
  end

  private

  def app_jobs
    root = Rails.root.join("app/jobs").to_s
    ApplicationJob.descendants.select { |job| job.instance_method(:perform).source_location&.first&.start_with?(root) }
  end

  def required_perform_arguments(job)
    job.instance_method(:perform).parameters.filter_map { |type, name| name.to_s if type == :req }
  end

  def scan_for_offenses
    SCANNED_GLOBS.flat_map { |glob| Rails.root.glob(glob) }.flat_map do |path|
      offenses_in(path.relative_path_from(Rails.root).to_s, path.read)
    end
  end

  # The lookahead stands in for \b, which never matches after `?`, and keeps
  # a bare find_by from matching inside a dynamic finder, caught whole.
  def offenses_in(relative_path, source)
    pattern = /\b(#{Regexp.union(TENANT_MODELS + REACHED_THROUGH_TASK + REACHED_THROUGH_PROJECT + REACHED_THROUGH_AGENT)})\.(#{Regexp.union(UNSCOPED_CALLS)}(?![\w?!])|find_by_\w+)/

    source.lines.each_with_index.filter_map do |line, index|
      next if line.match?(OPT_OUT) || line.strip.start_with?("#")
      next unless line.match?(pattern)

      "  #{relative_path}:#{index + 1}  #{line.strip}"
    end
  end
end
