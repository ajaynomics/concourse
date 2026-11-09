require "test_helper"

# Every queue a production job can land on has a worker. A narrowed worker list
# silently strands whatever it omits (Solid Queue has no exclusion syntax).
class ProductionQueueConfigTest < ActiveSupport::TestCase
  test "every enqueued queue in production has a worker and relay followers stay isolated" do
    queue = YAML.load(ERB.new(File.read(Rails.root.join("config/queue.yml"))).result, aliases: true).fetch("production")
    served = queue.fetch("workers").flat_map { |worker| Array(worker.fetch("queues")) }
    recurring = YAML.load_file(Rails.root.join("config/recurring.yml")).fetch("production").values
    jobs = Dir[Rails.root.join("app/jobs/*_job.rb")].map { |file| File.basename(file, ".rb").camelize.constantize }
    needed = jobs.map { |job| job.new.queue_name } + [ "default" ]
    needed << "solid_queue_recurring" if recurring.any? { |task| task.key?("command") }
    needed.uniq.each { |name| assert_includes served, name, "no worker serves #{name}" }
    followers = queue.fetch("workers").select { |worker| Array(worker["queues"]).include?("relay_follow") }
    assert_equal [ [ "relay_follow" ] ], followers.map { |worker| Array(worker["queues"]) }
    assert served.exclude?("*")
  end
end
