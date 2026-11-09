require "application_system_test_case"
require_relative "../support/connect_flow"

# The consent page shows the address that will be created as the person
# picks an organization, prefix and handle.
class ConnectAddressTest < ApplicationSystemTestCase
  include ConnectFlow

  setup do
    setup_connect
    @organization.namespaces.create!(name: "team")
    @other = Organization.create!(name: "Other Lab", slug: "other-lab", machine_clients: true)
    @other.memberships.create!(user: @owner)
    @other.namespaces.create!(name: "elsewhere")
  end

  teardown { teardown_connect }

  test "the address follows the chosen organization, prefix and handle" do
    sign_in_as(subject: @owner.ajent_sub, email: @owner.email, name: "Owner")
    visit connect_path(@connect_params)

    assert_selector "#connect_address", text: "machine-lab/machine-owner/assistant"
    assert_no_selector "#prefix option[value=elsewhere]:not([disabled])"
    select "team (Machine Lab)", from: "Address prefix"
    fill_in "Agent handle", with: "helper"
    assert_selector "#connect_address", text: "machine-lab/team/helper"

    choose "Other Lab"
    assert_selector "#connect_address", text: "other-lab/machine-owner/helper"
    select "elsewhere (Other Lab)", from: "Address prefix"
    assert_selector "#connect_address", text: "other-lab/elsewhere/helper"
  end
end
