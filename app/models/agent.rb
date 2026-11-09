class Agent < ApplicationRecord
  include NativeEndpoint
  # The person behind a token is not a member of the organization the agent
  # works in, or of any. Concourse admits people on the web, where it can see
  # a verified email; a token carries none.
  class Unadmitted < StandardError
    # Set when a valid machine credential named this agent, so a caller that
    # may act while unadmitted (an app disconnecting) knows whose it is.
    attr_reader :client_binding

    def initialize(message = nil, client_binding: nil)
      @client_binding = client_binding
      super(message)
    end
  end
  # Enrolled in an organization whose owners approve agents, and not yet
  # approved. Still unadmitted; the answer says what to wait for.
  class AwaitingApproval < Unadmitted; end
  # An owner declined it. Signing in again would not change that.
  class Declined < Unadmitted; end

  class OrganizationSelectionRequired < StandardError
    attr_reader :data

    def initialize(error, message, organizations:)
      @data = { error: error, message: message, organizations: organizations.map { |organization| { slug: organization.slug, name: organization.name } } }
      super(message)
    end
  end

  belongs_to :owner, class_name: "User", inverse_of: :agents
  belongs_to :organization
  belongs_to :namespace, optional: true
  has_many :received_tasks, class_name: "Task", foreign_key: :recipient_agent_id, dependent: :destroy, inverse_of: :recipient_agent
  has_many :sent_tasks, class_name: "Task", foreign_key: :caller_agent_id, dependent: :destroy, inverse_of: :caller_agent
  has_many :event_log, class_name: "AgentEvent", dependent: :delete_all, inverse_of: :agent
  has_many :participations, dependent: :delete_all
  has_many :projects, -> { order(:name) }, through: :participations
  has_one :client_binding, class_name: "Agent::ClientBinding", dependent: :nullify, inverse_of: :agent
  has_many :connect_grants, dependent: :delete_all
  has_one :push_config, dependent: :destroy
  has_many :connections, class_name: "Agent::Connection", dependent: :destroy

  # An agent works once admitted. Organizations that approve agents enrol new
  # ones unadmitted, for an owner to approve.
  attribute :admitted_at, :datetime, default: -> { Time.current }

  DIRECTORY_PAGE = 20
  DIRECTORY_MAX = 50

  # An agent belongs to its organization only while its owner does. Removing
  # someone keeps their agents and tasks, but takes the agents out of the
  # directory and out of reach until they are let back in.
  # Authorization must see external membership changes, not a request cache.
  scope :pending, -> { where(admitted_at: nil, declined_at: nil) }
  scope :declined, -> { where(admitted_at: nil).where.not(declined_at: nil) }
  scope :admitted, -> {
    where.not(admitted_at: nil).where(Membership.where("memberships.user_id = agents.owner_id AND memberships.organization_id = agents.organization_id").arel.exists).skip_query_cache! # tenancy-ok: correlated to the agent's own organization
  }

  # The directory: named agents, by owner and handle.
  scope :listed, -> { admitted.where.not(handle: nil).joins(:owner).preload(:owner, :namespace, :projects).order("users.handle", "agents.handle") }
  scope :in_project, ->(project) { where(id: project.participations.select(:agent_id)) }
  # Unlike named, this address scope also supports owner-only reconciliation
  # after admission has been withdrawn. It grants no agent API visibility.
  scope :at_address, ->(prefix, handle) {
    joins(:owner).left_joins(:namespace).where(handle: handle.to_s)
      .where("namespaces.name = :prefix OR (agents.namespace_id IS NULL AND users.handle = :prefix)", prefix: prefix.to_s)
  }

  validates :handle, allow_nil: true, format: { with: User::HANDLE_FORMAT }
  # The handle is unique under the agent's prefix. Without a namespace the
  # prefix is the owner's handle; with one, the owner may reuse the name
  # elsewhere, e.g. ajent/sam-lee and dana/sam-lee.
  validates :handle, uniqueness: { scope: :owner_id, conditions: -> { where(namespace_id: nil) } }, allow_nil: true, unless: :namespace_id?
  validates :handle, uniqueness: { scope: :namespace_id }, allow_nil: true, if: :namespace_id?
  validate :namespace_is_the_organizations, if: -> { namespace && (will_save_change_to_namespace_id? || will_save_change_to_organization_id?) }
  # A CIMD client_id is the harness, shared by every person who uses it.
  # One agent per owner per registration; a second agent is a second registration.
  validates :oauth_client_id, uniqueness: { scope: :owner_id }, allow_nil: true
  # Only the owner pages' card form; update_card keeps its own rules.
  validates :name, length: { maximum: 120 }, on: :owner_edit
  validates :description, length: { maximum: 4000 }, on: :owner_edit
  validate :owner_is_a_member, if: -> { new_record? || organization_id_changed? }
  validate :no_open_tasks_left_behind, if: -> { persisted? && organization_id_changed? }
  validate :user_client_is_not_reserved, if: :will_save_change_to_oauth_client_id?

  before_validation :land_in_organization, on: :create
  # A prefix stays with the organization that claimed it; a moved agent goes back to its owner's.
  before_validation -> { self.namespace = nil }, if: -> { persisted? && organization_id_changed? && namespace && namespace.organization_id != organization_id }
  # Projects are an organization's, so an agent that moves leaves them.
  before_save :await_approval_after_move, if: -> { persisted? && will_save_change_to_organization_id? }
  # A new agent, or one moved in, now waits for an owner. The bulk review a
  # switch to approval makes uses update_all, so it alerts no one: the owner
  # who flipped the switch is already looking.
  # Created pending, then touched again in the same transaction (a first
  # request stamps last_seen_at), so the create has its own hook.
  after_create_commit { ApprovalAlertJob.schedule(organization_id) if pending? }
  after_update_commit(if: -> { pending? && saved_change_to_admitted_at? }) { ApprovalAlertJob.schedule(organization_id) }
  after_update :leave_projects, if: :saved_change_to_organization_id?
  after_update :revoke_client_binding, if: -> { saved_change_to_organization_id? || saved_change_to_owner_id? }

  # A2A leaves the registry API to the implementer. Matches come back best
  # first; the caller still chooses whom to ask.
  def self.search(query, limit: DIRECTORY_PAGE)
    size = limit.to_i.clamp(1, DIRECTORY_MAX)
    terms = query.to_s.downcase.scan(/[a-z0-9]+/)
    return limit(size).to_a if terms.empty?

    all.map { |agent| [ agent, agent.match_score(terms) ] }
      .select { |_, score| score.positive? }
      .sort_by { |agent, score| [ -score, agent.qualified_handle ] }
      .first(size).map(&:first)
  end

  # A handle is looked up within one organization, under its prefix: the
  # agent's namespace, or its owner's handle when it has none.
  def self.named(prefix, handle)
    admitted.at_address(prefix, handle).first
  end

  # First sight of a client creates an unnamed agent; update_card sets the
  # handle. Until then the handle stays nil, which
  # the unique index allows more than once per owner.
  # Only the web admits people, so a token from someone who has never signed
  # in there creates nothing, not even an account holding a handle.
  def self.establish_from_introspection!(payload = nil, organization_slug: nil, **claims)
    payload ||= claims
    if ClientBinding.machine_payload?(payload)
      Ajent::Introspection.validate_machine!(payload)
      binding = ClientBinding.for_client(payload["client_id"])
      raise Ajent::Introspection::Rejected unless binding
      agent = binding.admitted_agent!
      organization_for_client!(owner: agent.owner, organization_slug: organization_slug, agent: agent) if Concourse.v3?
      agent.update!(last_seen_at: Time.current)
      return agent
    end
    raise Ajent::Introspection::Rejected if payload.key?("agent") || (payload.key?("token_use") && payload["token_use"] != "user")

    owner = User.find_by(ajent_sub: payload.fetch("sub").to_s)
    raise Unadmitted unless owner

    if Concourse.v3?
      # Selection failures must not enrich the owner or touch last_seen_at.
      agent = transaction do
        agent = for_client!(owner: owner, client_id: payload.fetch("client_id").to_s, organization_slug: organization_slug)
        User.find_or_create_from_subject!(ajent_sub: payload.fetch("sub"), email: email_from(payload), name: payload["name"].presence)
        agent
      end
      # Outside the transaction, so a new agent stays enrolled for approval.
      raise_unless_admitted(agent)
      return agent
    end

    owner = User.find_or_create_from_subject!(
      ajent_sub: payload.fetch("sub"),
      email: email_from(payload),
      name: payload["name"].presence
    )
    for_client!(owner: owner, client_id: payload.fetch("client_id").to_s)
  end

  # An agent works only while its owner belongs to its organization. Removing
  # someone from an organization stops their agents there at their next
  # request, without deleting anything.
  def self.for_client!(owner:, client_id:, organization_slug: nil)
    raise ArgumentError, "client_id required" if client_id.blank?
    raise Ajent::Introspection::Rejected if ClientBinding.for_client(client_id)

    if Concourse.v3?
      # Serialize first registration for this owner, including competing choices
      # for the same client. A later request may never retarget the winner.
      return owner.with_lock do
        agent = owner.agents.skip_query_cache!.find_by(oauth_client_id: client_id)
        raise_unless_admitted(agent) if agent

        organization = organization_for_client!(owner: owner, organization_slug: organization_slug, agent: agent)
        # Awaiting approval, a new agent is returned for the caller to refuse
        # after it commits; an owner can only approve what was kept.
        agent ||= owner.agents.create!(oauth_client_id: client_id, organization: organization,
          admitted_at: (Time.current unless organization.approves_members?))
        raise_unless_admitted(agent) unless agent.pending?

        agent.update!(last_seen_at: Time.current)
        agent
      end
    end

    agent = owner.agents.find_by(oauth_client_id: client_id)
    admitted = agent ? agent.admitted? : owner.memberships.exists?
    raise Unadmitted unless admitted

    agent ||= create_for_client(owner, client_id)
    agent.update!(last_seen_at: Time.current)
    agent
  end

  # last_seen_at moves when Ajent introspects the agent's token, which the
  # token cache holds for up to ten minutes. "Recently" is that window plus
  # a margin, not a presence protocol.
  RECENT = 15.minutes

  def admitted?
    self.class.admitted.where(organization_id: organization_id).exists?(id)
  end

  def pending?
    admitted_at.nil? && declined_at.nil?
  end

  def declined?
    admitted_at.nil? && declined_at.present?
  end

  # What #retire leaves: declined, and any app credential revoked.
  def retired?
    declined? && ClientBinding.all.skip_query_cache!.where(agent_id: id, revoked_at: nil).none?
  end

  # The owner's decision, as owner actions report it. An approved agent whose
  # person has since left the organization still reads admitted here; the
  # person must be let back in on the web.
  def admission_status
    if admitted_at then "admitted"
    elsif declined_at then "declined"
    else "awaiting_approval"
    end
  end

  def approve
    update!(admitted_at: Time.current, declined_at: nil)
  end

  # Kept, not deleted: its tasks stay with the agents it worked with, and the
  # same client asking again is refused rather than queued again.
  def decline
    update!(admitted_at: nil, declined_at: Time.current)
  end

  # Soft withdrawal keeps identity and correspondence. Reapproval may restore
  # user-client admission, but a machine reservation can never be unrevoked.
  def retire
    with_lock do
      decline unless admitted_at.nil? && declined_at.present?
      revoke_client_binding
    end
  end

  # What to tell a member's agent that may not work yet, and Unadmitted when
  # its owner is not a member at all.
  def admission_refusal
    return Unadmitted unless owner.organizations.include?(organization)

    if pending? then AwaitingApproval
    elsif declined_at then Declined
    else Unadmitted
    end
  end

  def recently_seen?
    last_seen_at.present? && last_seen_at > RECENT.ago
  end

  # Skills as update_card stored them (A2A AgentSkill, §4.4.5), for pages.
  def skill_list
    Array(skills).filter_map { |skill| skill.stringify_keys if skill.is_a?(Hash) }
  end

  # Tasks in the given scope that wait on this agent to act, oldest first:
  # SUBMITTED, or INPUT_REQUIRED that the caller has answered (Task#actionable?).
  def waiting_tasks(scope)
    scope.where(recipient_agent_id: id).unfinished.includes(:messages)
      .select(&:actionable?).sort_by(&:actionable_since)
  end

  def unnamed?
    handle.nil?
  end

  def prefix
    namespace&.name || owner.handle
  end

  def qualified_handle
    return if handle.blank?

    "#{prefix}/#{handle}"
  end

  # Sorted, so the list reads the same however it was assigned.
  def project_slugs
    projects.map(&:slug).sort
  end

  def directory_entry
    {
      # The id owner actions take (Agent::OwnerAuthority).
      "id" => id,
      "handle" => qualified_handle,
      "organization" => organization.slug,
      "name" => name,
      "description" => description,
      "skills" => skills,
      "harness" => harness,
      "projects" => project_slugs,
      "url" => A2a::Card.endpoint_url(self)
    }.tap do |entry|
      # A2A AgentInterface has no per-interface auth override (§4.4.6).
      # Direct discovery is opt-in and separate from the gateway OAuth card.
      entry["nativeCardUrl"] = native_card_url if native_delivery_available? && native_discoverable?
    end
  end

  # Owner actions answer with this: enough to identify the agent, no card content.
  def admission_entry
    { "id" => id, "address" => qualified_handle, "status" => admission_status }
  end

  # The waiting list, as the web's settings page shows it to owners.
  def pending_entry
    {
      "id" => id,
      "address" => qualified_handle,
      "name" => name,
      "owner" => owner.handle,
      "client_id" => oauth_client_id,
      "requested_at" => created_at.iso8601
    }
  end

  # How well this agent's card matches a directory query. A match in the
  # handle or name counts for more than a passing mention in the description.
  def match_score(terms)
    fields = [
      [ qualified_handle, 5 ], [ name, 4 ], [ skill_tags, 4 ], [ skill_text, 3 ],
      [ project_text, 3 ], [ owner.handle, 3 ], [ description, 2 ], [ harness, 1 ]
    ].map { |text, weight| [ text.to_s.downcase, weight ] }

    terms.sum { |term| fields.sum { |text, weight| text.include?(term) ? weight : 0 } }
  end

  # Ajent's introspection username is the owner's email for a Concourse
  # token (RFC 7662).
  def self.email_from(payload)
    [ payload["username"], payload["email"] ].each do |value|
      return value if value.to_s.include?("@")
    end
    nil
  end

  def self.create_for_client(owner, client_id)
    owner.agents.create!(oauth_client_id: client_id)
  rescue ActiveRecord::RecordNotUnique
    owner.agents.find_by!(oauth_client_id: client_id)
  end

  def self.organization_for_client!(owner:, organization_slug:, agent: nil)
    organizations = owner.organizations.skip_query_cache!.order(:slug).to_a
    raise Unadmitted if organizations.empty?
    return agent.organization if agent && organization_slug.nil?

    if organization_slug.nil?
      # An organization that approves agents is never chosen by default.
      return organizations.sole if organizations.one? && !organizations.sole.approves_members?

      raise OrganizationSelectionRequired.new("organization_required",
        "Select an organization with the Concourse-Organization header before enrolling this agent.", organizations: organizations)
    end

    organization = organizations.find { |candidate| candidate.slug == organization_slug } if organization_slug.is_a?(String) && organization_slug.match?(Organization::SLUG_FORMAT)
    unless organization
      raise OrganizationSelectionRequired.new("organization_invalid",
        "Concourse-Organization must name an organization you currently belong to.", organizations: organizations)
    end
    if agent && agent.organization_id != organization.id
      raise OrganizationSelectionRequired.new("organization_conflict",
        "This client is already bound to another organization; Concourse-Organization cannot move it.", organizations: organizations)
    end
    organization
  end
  def self.raise_unless_admitted(agent)
    return if agent.admitted?

    raise agent.admission_refusal
  end
  private_class_method :email_from, :create_for_client, :organization_for_client!, :raise_unless_admitted

  # Tasks stay with the organization they were sent in. Moving an agent with
  # work still open would strand that work where the agent no longer is.
  def open_tasks?
    received_tasks.unfinished.or(sent_tasks.unfinished).exists? || pending_relay_routes?
  end

  private

  def user_client_is_not_reserved
    errors.add(:oauth_client_id, "is reserved for a machine client") if oauth_client_id.present? && ClientBinding.for_client(oauth_client_id)
  end

  def revoke_client_binding
    ClientBinding.all.skip_query_cache!.find_by(agent_id: id)&.revoke!
  end

  # An agent moved into an organization that approves agents waits for an
  # owner there, like one that enrolled there.
  def await_approval_after_move
    self.admitted_at = nil if owner_id != User.system.id && organization.approves_members?
  end

  def land_in_organization
    return if organization || owner.nil?

    if Concourse.v3?
      organizations = owner.organizations.skip_query_cache!.to_a
      if organizations.one?
        self.organization = organizations.sole
      elsif organizations.many?
        errors.add(:organization, "must be selected when the owner belongs to multiple organizations")
      end
    else
      self.organization = owner.first_organization
    end
  end

  # A prefix stays with the organization that claimed it.
  def namespace_is_the_organizations
    errors.add(:namespace, :invalid) unless namespace.organization_id == organization_id
  end

  def owner_is_a_member
    return if owner.nil? || organization.nil?

    member = if Concourse.v3?
      owner.memberships.skip_query_cache!.exists?(organization_id: organization.id)
    else
      owner.organizations.include?(organization)
    end
    errors.add(:organization, :not_a_member) unless member
  end

  def no_open_tasks_left_behind
    errors.add(:organization, :open_tasks) if open_tasks?
  end

  def leave_projects
    participations.delete_all
  end

  def project_text
    projects.flat_map { |project| [ project.slug, project.name ] }.join(" ")
  end

  def skill_tags
    skill_list.flat_map { |skill| Array(skill["tags"]) }.join(" ")
  end

  def skill_text
    skill_list.flat_map { |skill| [ skill["name"], skill["description"], *Array(skill["examples"]) ] }.join(" ")
  end
end
