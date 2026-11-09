require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "the system user has the concourse handle and no subject" do
    user = User.system

    assert_equal "concourse", user.handle
    assert_nil user.ajent_sub
    assert user.system?
    assert_equal user, User.system
  end

  test "a person cannot take the system handle" do
    User.system
    user = User.new(ajent_sub: "1", handle: "concourse", email: "c@example.com")

    assert_not user.valid?
  end

  test "a non-system user requires a subject" do
    user = User.new(handle: "ajay")

    assert_not user.valid?
    assert user.errors[:ajent_sub].any?
  end

  test "signing in creates the account and nothing else" do
    user = User.upsert_from_identity!(subject: "1", user_info: { "email" => "ajay@example.com", "email_verified" => true })

    assert user.persisted?
    assert_empty user.organizations
  end

  test "a verified email joins the organization claiming its domain, as a member" do
    example = Organization.create!(name: "Example", email_domains: "Example.com\nexample.org")
    Organization.create!(name: "Other", email_domains: "other.test")

    user = User.upsert_from_identity!(subject: "1", user_info: { "email" => "Ajay@EXAMPLE.com", "email_verified" => true })

    assert_equal [ example ], user.organizations.to_a
    assert user.memberships.all? { |membership| membership.role == "member" }
    assert_equal "example.com", user.verified_email_domain
  end

  test "whether the email was verified is kept until the next sign-in" do
    user = User.upsert_from_identity!(subject: "1", user_info: { "email" => "ajay@example.com", "email_verified" => false })
    assert_nil user.verified_email_domain

    User.upsert_from_identity!(subject: "1", user_info: { "email" => "ajay@example.com", "email_verified" => "true" })
    assert_equal "example.com", user.reload.verified_email_domain
  end

  test "an unverified email joins nothing" do
    Organization.create!(name: "Example", email_domains: "example.com")

    [ false, "false", nil ].each_with_index do |verified, index|
      user = User.upsert_from_identity!(subject: "u#{index}", user_info: { "email" => "u#{index}@example.com", "email_verified" => verified })
      assert_empty user.organizations, verified.inspect
    end
  end

  test "the domain match is exact, not a suffix" do
    Organization.create!(name: "Example", email_domains: "example.com")

    user = User.upsert_from_identity!(subject: "1", user_info: { "email" => "ajay@mail.example.com", "email_verified" => true })

    assert_empty user.organizations
  end

  test "signing in again keeps existing memberships and their roles" do
    organization = Organization.create!(name: "Example", email_domains: "example.com")
    user = User.create!(ajent_sub: "1", handle: "ajay", email: "ajay@example.com")
    organization.memberships.create!(user: user, role: "owner")

    User.upsert_from_identity!(subject: "1", user_info: { "email" => "ajay@example.com", "email_verified" => true })

    assert_equal [ "owner" ], user.memberships.reload.map(&:role)
  end

  test "handle collisions get a suffix" do
    User.create!(ajent_sub: "1", handle: "ajay", email: "one@example.com")

    user = User.upsert_from_identity!(subject: "2", user_info: { "email" => "ajay@other.example", "name" => "Other" })

    assert_equal "ajay-2", user.handle
  end

  test "a reserved handle is skipped instead of failing validation" do
    user = User.upsert_from_identity!(subject: "9", user_info: { "email" => "concourse@example.com", "name" => "C" })

    assert user.persisted?
    assert_equal "concourse-2", user.handle
    assert_not_equal User::SYSTEM_HANDLE, user.handle
  end

  test "web sign-in does not rename a user who already has an agent" do
    Organization.default.memberships.create!(user: User.find_or_create_from_subject!(ajent_sub: "42"))
    agent = Agent.establish_from_introspection!("sub" => "42", "client_id" => "client-1")
    assert_equal "sub-42", agent.owner.handle

    user = User.upsert_from_identity!(subject: "42", user_info: { "email" => "ajay@example.com", "name" => "Ajay" })

    assert_equal "sub-42", user.handle
    assert_equal "ajay@example.com", user.email
    assert_equal "Ajay", user.name
  end
end
