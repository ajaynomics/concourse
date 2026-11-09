require "test_helper"

class RelayNetworkSlotTest < ActiveSupport::TestCase
  setup do
    # tenancy-ok: synthetic shared capacity rows have no content or credentials.
    RelayNetworkSlot.delete_all
    @organization = Organization.create!(name: "First", slug: "first")
  end

  test "dispatch slots are cross-process database records with two per organization and eight globally" do
    first = RelayNetworkSlot.acquire(kind: :dispatch, organization: @organization, holder: "a")
    second = RelayNetworkSlot.acquire(kind: :dispatch, organization: @organization, holder: "b")
    assert first
    assert second
    assert_nil RelayNetworkSlot.acquire(kind: :dispatch, organization: @organization, holder: "excess")
    3.times do |i|
      organization = Organization.create!(name: "Other #{i}", slug: "other-#{i}")
      2.times { |j| assert RelayNetworkSlot.acquire(kind: :dispatch, organization: organization, holder: "#{i}-#{j}") }
    end
    extra = Organization.create!(name: "Excess", slug: "excess")
    assert_nil RelayNetworkSlot.acquire(kind: :dispatch, organization: extra, holder: "full")
    first.release("a")
    assert RelayNetworkSlot.acquire(kind: :dispatch, organization: extra, holder: "after-release")
  end

  test "follow slots are independent with one per organization and four globally" do
    slot = RelayNetworkSlot.acquire(kind: :follow, organization: @organization, holder: "f")
    assert slot
    assert_nil RelayNetworkSlot.acquire(kind: :follow, organization: @organization, holder: "another")
    3.times do |i|
      organization = Organization.create!(name: "Other #{i}", slug: "other-#{i}")
      assert RelayNetworkSlot.acquire(kind: :follow, organization: organization, holder: "#{i}")
    end
    assert RelayNetworkSlot.acquire(kind: :dispatch, organization: @organization, holder: "independent")
    extra = Organization.create!(name: "Excess", slug: "excess")
    assert_nil RelayNetworkSlot.acquire(kind: :follow, organization: extra, holder: "full")
  end

  test "expiry permits observation capacity recovery but stale holder cannot release its successor" do
    now = Time.current
    old = RelayNetworkSlot.acquire(kind: :follow, organization: @organization, holder: "old", now: now)
    replacement = RelayNetworkSlot.acquire(kind: :follow, organization: @organization, holder: "new", now: now + 61.seconds)
    assert_equal old.id, replacement.id
    old.release("old")
    assert replacement.reload.held_by?("new", now: now + 61.seconds)
  end

  test "schema-load initialization preserves active holders" do
    slot = RelayNetworkSlot.acquire(kind: :follow, organization: @organization, holder: "running")
    assert_nil RelayNetworkSlot.acquire(kind: :follow, organization: @organization, holder: "contender")
    assert slot.reload.held_by?("running")
    assert_equal 12, RelayNetworkSlot.count
  end
end
