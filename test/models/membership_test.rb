require "test_helper"

class MembershipTest < ActiveSupport::TestCase
  setup do
    @organization = Organization.create!(name: "Acme")
    @owner = User.create!(ajent_sub: "1", handle: "ajay")
    @member = User.create!(ajent_sub: "2", handle: "riley")
    @ownership = @organization.memberships.create!(user: @owner, role: "owner")
    @membership = @organization.memberships.create!(user: @member)
  end

  test "a membership is a member unless it says owner" do
    assert_equal "member", @membership.role
    assert_not @organization.memberships.build(user: User.create!(ajent_sub: "3", handle: "sam"), role: "admin").valid?
  end

  test "one membership per person per organization" do
    assert_not @organization.memberships.build(user: @member).valid?
  end

  test "the last owner can be neither removed nor demoted" do
    assert_not @ownership.remove
    assert @ownership.reload.persisted?
    assert_not @ownership.update(role: "member")
    assert @ownership.reload.last_owner?

    assert @membership.remove
  end

  test "an owner can go once another owner remains" do
    @membership.update!(role: "owner")

    assert @ownership.remove
  end

  test "deleting the user takes their memberships with them, last owner or not" do
    @owner.destroy!

    assert_equal [ @membership ], @organization.memberships.reload.to_a
  end
end
