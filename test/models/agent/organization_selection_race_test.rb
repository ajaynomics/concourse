require "test_helper"
require "timeout"

class Agent::OrganizationSelectionRaceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @settings = Rails.application.config.x.concourse
    @old_release = @settings.release_line
    @settings.release_line = 3
    suffix = SecureRandom.hex(6)
    @organizations = %w[first second].map { |name| Organization.create!(name: "Synthetic #{name}", slug: "selection-#{name}-#{suffix}") }
    @owner = User.create!(ajent_sub: "selection-race-#{suffix}", handle: "selection-race-#{suffix}", organizations: @organizations)
    @client_id = "selection-client-#{suffix}"
  end

  teardown do
    @settings.release_line = @old_release
    @owner&.destroy!
    @organizations&.each do |organization|
      organization.agents.destroy_all
      organization.destroy!
    end
  end

  test "same client and choice on separate connections enroll exactly one agent" do
    results = race(@organizations.first.slug, @organizations.first.slug)
    assert results.all? { |result| result.is_a?(Agent) }, results.inspect
    assert_equal 1, results.map(&:id).uniq.size
    assert_equal 1, @owner.agents.where(oauth_client_id: @client_id).count
    assert_equal @organizations.first.id, results.first.organization_id
  end

  test "competing choices on separate connections cannot retarget the winning client" do
    results = race(*@organizations.map(&:slug))
    winners = results.grep(Agent)
    conflicts = results.grep(Agent::OrganizationSelectionRequired)
    assert_equal 1, winners.size, results.inspect
    assert_equal 1, conflicts.size, results.inspect
    assert_equal "organization_conflict", conflicts.sole.data[:error]
    assert_equal winners.sole.organization_id, @owner.agents.find_by!(oauth_client_id: @client_id).organization_id
    assert_equal 1, @owner.agents.where(oauth_client_id: @client_id).count
  end

  test "concurrent ambiguous enrollment never creates an agent" do
    results = race(nil, nil)
    assert results.all? { |result| result.is_a?(Agent::OrganizationSelectionRequired) }, results.inspect
    assert results.all? { |result| result.data[:error] == "organization_required" }
    assert_empty @owner.agents.where(oauth_client_id: @client_id)
  end

  private

  def race(*slugs)
    ready = Queue.new
    go = Queue.new
    threads = slugs.map do |slug|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          ready << connection.object_id
          go.pop
          begin
            Agent.for_client!(owner: User.find(@owner.id), client_id: @client_id, organization_slug: slug)
          rescue StandardError => error
            error
          end
        end
      end
    end
    ids = Timeout.timeout(10) { slugs.size.times.map { ready.pop } }
    assert_equal slugs.size, ids.uniq.size, "each request has a separate database connection"
    slugs.size.times { go << true }
    Timeout.timeout(10) { threads.map(&:value) }
  ensure
    threads&.each { |thread| thread.kill.join if thread.alive? }
  end
end
