class Organization < ApplicationRecord
  # The tenant. Agents and tasks carry organization_id directly, so a scoped
  # query is one column and never a join through people.
  SLUG_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  # An organization's pages start with its slug, so a slug may not be the
  # first word of any other path.
  # The platform's own names are reserved too, so no organization can pass
  # for Concourse itself; the default organization is the one exception.
  RESERVED_SLUGS = %w[a2a admin agents ahoy api assets auth cable concourse connect default developer extensions help join llms manifest mcp organization organizations privacy projects push_subscription rails robots service-worker settings sign_in sign_out sitemap social-card support tasks terms up www].freeze
  DOMAIN_FORMAT = /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\z/
  # Anyone can have an address at these, so claiming one would admit
  # strangers.
  PUBLIC_EMAIL_DOMAINS = %w[
    126.com 163.com aol.com fastmail.com gmail.com gmx.com gmx.net googlemail.com hey.com hotmail.com
    icloud.com live.com mac.com mail.com me.com msn.com outlook.com pm.me proton.me protonmail.com
    qq.com yahoo.com yandex.com yandex.ru ymail.com zoho.com
  ].freeze

  # Declared first so an organization with agents or tasks refuses to go
  # before its memberships are touched.
  has_many :agents, dependent: :restrict_with_error
  has_many :tasks, dependent: :restrict_with_error
  has_many :relay_deliveries, dependent: :restrict_with_error
  has_many :relay_tasks, dependent: :restrict_with_error
  has_many :relay_contexts, dependent: :restrict_with_error
  has_many :memberships, dependent: :destroy
  has_many :removals, dependent: :delete_all
  has_many :join_requests, dependent: :delete_all
  has_many :invitations, dependent: :delete_all
  has_many :projects, dependent: :destroy
  has_many :namespaces, dependent: :restrict_with_error
  has_many :users, through: :memberships

  GUIDE_NOTE_LIMIT = 10_000
  # automatic: a verified email at a claimed domain joins, and members' agents
  # enrol themselves. approval: an owner approves every person and agent.
  ADMISSIONS = %w[automatic approval].freeze
  # With creation open anyone signed in may found an organization, and each
  # one holds its own share of the waiting slots (A2a::Waiters). A few a day
  # is plenty for a person and too few to take every share. Operators
  # creating organizations directly are not counted against it.
  FOUNDING_LIMIT = 2
  FOUNDING_WINDOW = 24.hours

  attr_accessor :founder

  validates :name, presence: true, length: { maximum: 120 }
  validates :guide_note, length: { maximum: GUIDE_NOTE_LIMIT }
  validates :admission, inclusion: { in: ADMISSIONS }
  validates :slug, presence: true, uniqueness: true, format: { with: SLUG_FORMAT }
  validates :slug, exclusion: { in: RESERVED_SLUGS }, unless: :platform?
  validate :email_domains_are_domains
  validate :email_domains_are_claimable
  validate :legacy_admits_no_machine_clients, if: -> { will_save_change_to_machine_clients?(to: true) }
  validate :founder_within_limit, on: :create, if: :founder

  before_validation :normalize_email_domains
  before_validation :derive_slug_from_name, on: :create
  after_create :ensure_network_agent, if: -> { Concourse.v3? }
  # Turning approval on reviews every agent already here, rather than
  # keeping the ones that enrolled themselves.
  after_update :review_agents, if: -> { saved_change_to_admission?(to: "approval") }
  # Turning it off admits whoever was waiting, as automatic admission would.
  after_update :admit_waiting, if: -> { saved_change_to_admission?(to: "automatic") }

  # The platform's own organization, not a customer's. It serves the public
  # cards without an organization in the path, and holds only the system user
  # and concourse/conformance.
  def self.default
    find_or_create_by!(slug: default_slug) { |organization| organization.name = default_slug.titleize } # tenancy-ok: the default organization is global by definition
  end

  def self.default_slug
    Concourse.config(:concourse, :default_organization).presence || "concourse"
  end

  # The organization whose agents the older card addresses, the ones without
  # an organization in them, still lead to. Nil when there is none.
  def self.legacy
    slug = legacy_slug
    find_by(slug: slug) if slug # tenancy-ok: one configured organization, looked up by slug
  end

  def self.legacy_slug
    Concourse.config(:concourse, :legacy_organization).presence
  end

  def self.creation_open?
    Concourse.config(:concourse, :organization_creation) == "open"
  end

  # Few organizations, and the list is matched exactly, so it is read here
  # rather than pattern-matched in SQL.
  def self.claiming_email_domain(domain)
    return [] if domain.blank?

    all.select { |organization| organization.email_domain_list.include?(domain.downcase) } # tenancy-ok: admission looks across every organization by design
  end

  # Creating an organization makes its creator the first owner, in one step,
  # so there is never an organization nobody can administer.
  def self.create_with_owner!(name:, owner:, &)
    transaction do
      organization = create!(name: name, admission: "approval", &)
      organization.memberships.create!(user: owner, role: "owner")
      organization
    end
  end

  # Self-service creation by a signed-in person, held to the founding limit.
  def self.found!(name:, founder:)
    create_with_owner!(name: name, owner: founder) { |organization| organization.founder = founder }
  end

  # Unattended credentials, operator-bound or joined through /connect, work
  # here only while an owner keeps this on. Admission reads it on every
  # request, so turning it off refuses them at once; their bindings stay, and
  # turning it back on resumes them.
  def machine_clients_allowed?
    machine_clients? && !legacy?
  end

  def legacy?
    slug == self.class.legacy_slug
  end

  def approves_members?
    admission == "approval"
  end

  def review_agents
    agents.where.not(owner: User.system).update_all(admitted_at: nil)
  end

  def admit_waiting
    agents.pending.update_all(admitted_at: Time.current)
    join_requests.find_each(&:approve)
    join_requests.reset
  end

  def email_domain_list
    email_domains.to_s.split
  end

  def mail_health(now: Time.current)
    MailHealth.new(self, now: now)
  end

  def to_s
    name
  end

  def to_param
    slug
  end

  def platform?
    slug == self.class.default_slug
  end

  private

  def ensure_network_agent
    A2a::Network.ensure!(self)
  end

  # Stored one per line, lowercase, without a leading @, whatever was typed.
  def normalize_email_domains
    domains = email_domains.to_s.split(/[\s,;]+/).map { |domain| domain.downcase.delete_prefix("@") }
    self.email_domains = domains.compact_blank.uniq.join("\n").presence
  end

  # The legacy organization is a tenant whose authorization stays as it was:
  # it never admits unattended credentials, whatever this setting says.
  def legacy_admits_no_machine_clients
    errors.add(:machine_clients, :legacy) if legacy?
  end

  def founder_within_limit
    founded = founder.memberships.owners.where(created_at: FOUNDING_WINDOW.ago..).count
    errors.add(:base, :founding_limit, count: FOUNDING_LIMIT) if founded >= FOUNDING_LIMIT
  end

  def email_domains_are_domains
    invalid = email_domain_list.reject { |domain| domain.match?(DOMAIN_FORMAT) }
    errors.add(:email_domains, :invalid_domains, domains: invalid.to_sentence) if invalid.any?
  end

  # One organization per domain, never a public email provider, and only a
  # domain the person adding it has a verified address at: otherwise any
  # owner could enrol another company's people. The console, which has no
  # Current.user, is the operator's way past the last rule.
  def email_domains_are_claimable
    domains = email_domain_list
    public_domains = domains & PUBLIC_EMAIL_DOMAINS
    errors.add(:email_domains, :public_domains, domains: public_domains.to_sentence) if public_domains.any?

    taken = domains.select { |domain| (Organization.claiming_email_domain(domain) - [ self ]).any? }
    errors.add(:email_domains, :taken, domains: taken.to_sentence) if taken.any?

    return unless Current.user

    added = domains - email_domains_was.to_s.split
    unproven = added - [ Current.user.verified_email_domain ]
    errors.add(:email_domains, :unproven, domains: unproven.to_sentence) if unproven.any?
  end

  def derive_slug_from_name
    return if slug.present? || name.blank?

    base = name.parameterize.presence || SecureRandom.alphanumeric(8).downcase
    candidate = base
    suffix = 2
    while RESERVED_SLUGS.include?(candidate) || Organization.exists?(slug: candidate) # tenancy-ok: slugs are unique across organizations
      candidate = "#{base}-#{suffix}"
      suffix += 1
    end
    self.slug = candidate
  end
end
