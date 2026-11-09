require "test_helper"

class OrganizationTasksChannelTest < ActionCable::Channel::TestCase
  setup do
    @acme = Organization.create!(name: "Acme")
    @other = Organization.create!(name: "Other")
    @kim = User.create!(ajent_sub: "1", handle: "kim", organizations: [ @acme ])
  end

  test "a member hears their own organization's task refreshes and no other's" do
    stub_connection current_user: @kim

    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name([ @acme, "tasks" ])
    assert subscription.confirmed?
    assert_has_stream Turbo::StreamsChannel.send(:stream_name_from, [ @acme, "tasks" ])

    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name([ @other, "tasks" ])
    assert subscription.rejected?
  end

  test "someone removed from the organization can no longer subscribe with its stream name" do
    name = Turbo::StreamsChannel.signed_stream_name([ @acme, "tasks" ])
    @acme.memberships.find_by!(user: @kim).remove
    stub_connection current_user: @kim.reload

    subscribe signed_stream_name: name
    assert subscription.rejected?
  end
end
