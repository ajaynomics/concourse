require "test_helper"

class OrganizationTest < ActiveSupport::TestCase
  test "the slug comes from the name and stays unique" do
    assert_equal "acme-labs", Organization.create!(name: "Acme Labs").slug
    assert_equal "acme-labs-2", Organization.create!(name: "Acme  Labs!").slug
  end

  test "a slug must be URL-safe" do
    assert_not Organization.new(name: "X", slug: "Not Safe").valid?
  end

  test "a slug is never the first word of another path" do
    first_words = Rails.application.routes.routes.filter_map { |route| route.path.spec.to_s[%r{\A/([^/(:*.]+)}, 1] }
    taken = first_words.uniq.grep(Organization::SLUG_FORMAT)

    assert_empty taken - Organization::RESERVED_SLUGS
    assert_not Organization.new(name: "Tasks", slug: "tasks").valid?
    assert_equal "agents-2", Organization.create!(name: "Agents").slug
  end

  test "email domains are stored one per line, lowercase, without an @" do
    organization = Organization.create!(name: "Acme", email_domains: "@Acme.com, acme.org\n\nacme.com")

    assert_equal "acme.com\nacme.org", organization.email_domains
    assert_equal %w[acme.com acme.org], organization.email_domain_list
  end

  test "something that is not a domain is refused" do
    organization = Organization.new(name: "Acme", email_domains: "acme.com localhost not_a.domain")

    assert_not organization.valid?
    assert_includes organization.errors[:email_domains].sole, "localhost and not_a.domain"
  end

  test "an organization claims a domain only by exact match" do
    acme = Organization.create!(name: "Acme", email_domains: "acme.com")

    assert_equal [ acme ], Organization.claiming_email_domain("ACME.com")
    assert_empty Organization.claiming_email_domain("mail.acme.com")
    assert_empty Organization.claiming_email_domain(nil)
  end

  test "a domain belongs to one organization" do
    Organization.create!(name: "Acme", email_domains: "acme.com")
    rival = Organization.new(name: "Rival", email_domains: "ACME.com")

    assert_not rival.valid?
    assert_includes rival.errors[:email_domains].sole, "acme.com"
  end

  test "a public email provider is never an organization's domain" do
    organization = Organization.new(name: "Acme", email_domains: "gmail.com acme.com")

    assert_not organization.valid?
    assert_includes organization.errors[:email_domains].sole, "gmail.com"
  end

  test "on the web, an owner adds only the domain of their own verified email" do
    organization = Organization.create!(name: "Acme")
    Current.user = User.create!(ajent_sub: "1", handle: "kim", email: "kim@acme.com", email_verified: true)

    assert_not organization.update(email_domains: "other.com")
    assert organization.update(email_domains: "acme.com")

    Current.user.update!(email_verified: false)
    assert_not organization.update(email_domains: "acme.com acme.org")
    assert organization.reload.update(name: "Acme Labs"), "a domain already there needs no proof again"
  ensure
    Current.reset
  end

  test "the console adds any domain that is not taken or public" do
    assert Organization.create(name: "Acme", email_domains: "acme.com").persisted?
  end

  test "no organization takes the platform's names, except the platform itself" do
    assert Organization.default.platform?
    %w[concourse default admin www].each do |slug|
      assert_not Organization.new(name: "X", slug: slug).valid?, slug
    end
    assert_equal "concourse-2", Organization.create!(name: "Concourse").slug
  end

  test "its creator is its first owner" do
    user = User.create!(ajent_sub: "1", handle: "ajay")

    organization = Organization.create_with_owner!(name: "Acme", owner: user)

    assert_equal [ [ user, "owner" ] ], organization.memberships.map { |membership| [ membership.user, membership.role ] }
  end

  test "a person founds at most two organizations a day; operators are not counted" do
    user = User.create!(ajent_sub: "1", handle: "ajay")
    2.times { |index| Organization.found!(name: "Team #{index}", founder: user) }

    error = assert_raises(ActiveRecord::RecordInvalid) { Organization.found!(name: "Third", founder: user) }
    assert_includes error.record.errors.full_messages.to_sentence, "at most 2 organizations a day"
    assert_nil Organization.find_by(name: "Third")
    assert Organization.create_with_owner!(name: "By an operator", owner: user).persisted?

    travel 25.hours do
      assert Organization.found!(name: "Next day", founder: user).persisted?
    end
  end

  test "the default organization is the configured slug, made on first use" do
    assert_equal [ "concourse", "Concourse" ], [ Organization.default.slug, Organization.default.name ]

    previous = Rails.application.config.x.concourse.default_organization
    Rails.application.config.x.concourse.default_organization = "home"

    organization = Organization.default
    assert_equal [ "home", "Home" ], [ organization.slug, organization.name ]
    assert_equal organization, Organization.default
  ensure
    Rails.application.config.x.concourse.default_organization = previous
  end

  test "an organization with agents cannot be deleted" do
    organization = Organization.create!(name: "Acme")
    user = User.create!(ajent_sub: "1", handle: "ajay", organizations: [ organization ])
    Agent.create!(owner: user, oauth_client_id: "a")

    assert_not organization.destroy
    assert_equal 1, organization.memberships.count
  end

  test "machine clients are off until an owner turns them on, and never in the legacy organization" do
    settings = Rails.application.config.x.concourse
    previous = settings.legacy_organization
    organization = Organization.create!(name: "Acme")
    assert_not organization.machine_clients_allowed?
    organization.update!(machine_clients: true)
    assert organization.machine_clients_allowed?

    legacy = Organization.create!(name: "Legacy")
    settings.legacy_organization = legacy.slug
    assert_not legacy.update(machine_clients: true)
    assert_includes legacy.errors.full_messages, "Machine clients can't be turned on for the legacy organization"

    # Already on when it became the legacy organization: still refused, and
    # its other settings still save.
    settings.legacy_organization = organization.slug
    assert_not organization.machine_clients_allowed?
    assert organization.update(name: "Acme Labs")
  ensure
    settings.legacy_organization = previous
  end
end
