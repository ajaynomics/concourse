require "test_helper"

# Owners hear that someone is waiting, by Web Push and, when SMTP is set, by
# email. Neither carries a name or any content.
class ApprovalAlertJobTest < ActiveJob::TestCase
  setup do
    @vapid = Rails.application.config.x.vapid
    @smtp = Rails.application.config.x.smtp
    @cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    key = WebPush.generate_key
    Rails.application.config.x.vapid = { subject: "mailto:test@example.com", public_key: key.public_key, private_key: key.private_key }

    @firm = Organization.create!(name: "Firm", slug: "firm", email_domains: "firm.test", admission: "approval")
    @boss = User.create!(ajent_sub: "1", handle: "boss", email: "boss@firm.test", email_verified: true)
    @firm.memberships.create!(user: @boss, role: "owner")
    @member = User.create!(ajent_sub: "2", handle: "member", email: "member@firm.test", email_verified: true)
    @firm.memberships.create!(user: @member)
    @subscription = @boss.push_subscriptions.create!(endpoint: "https://fcm.googleapis.com/fcm/send/abc", p256dh_key: "p", auth_key: "a")
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    Rails.application.config.x.vapid = @vapid
    Rails.application.config.x.smtp = @smtp
    Rails.cache = @cache
  end

  test "a request to join queues one alert after a short wait" do
    applicant = User.create!(ajent_sub: "3", handle: "applicant", email: "applicant@firm.test", email_verified: true)
    assert_enqueued_with(job: ApprovalAlertJob, at: ApprovalAlertJob::GRACE.from_now) do
      @firm.join_requests.create!(user: applicant)
    end
  end

  test "a new or moved agent queues an alert, but the review a switch makes and an approval do not" do
    agent = nil
    assert_enqueued_jobs 1, only: ApprovalAlertJob do
      agent = @boss.agents.create!(organization: @firm, oauth_client_id: "new", admitted_at: nil)
    end
    clear_enqueued_jobs
    agent.approve
    assert_no_enqueued_jobs only: ApprovalAlertJob

    open = Organization.create!(name: "Open", slug: "open")
    @boss.memberships.create!(organization: open)
    mover = @boss.agents.create!(organization: open, oauth_client_id: "mover", handle: "mover")
    clear_enqueued_jobs
    assert_enqueued_jobs 1, only: ApprovalAlertJob do
      mover.update!(organization: @firm)
    end

    clear_enqueued_jobs
    @firm.update!(admission: "automatic")
    @firm.update!(admission: "approval")
    assert_no_enqueued_jobs only: ApprovalAlertJob
  end

  test "a burst of requests becomes one alert, sent by the newest job" do
    3.times { |n| @firm.join_requests.create!(user: User.create!(ajent_sub: "b#{n}", handle: "b#{n}", email: "b#{n}@firm.test")) }
    assert_equal 1, deliveries { perform_enqueued_jobs }.size
  end

  test "owners get a push with counts and no names; members get nothing" do
    @member.push_subscriptions.create!(endpoint: "https://fcm.googleapis.com/fcm/send/other", p256dh_key: "p", auth_key: "a")
    @firm.join_requests.create!(user: User.create!(ajent_sub: "3", handle: "applicant-secret", email: "applicant@firm.test"))
    @boss.agents.create!(organization: @firm, oauth_client_id: "new", handle: "agent-secret", admitted_at: nil)

    payloads = deliveries { perform_enqueued_jobs }

    assert_equal 1, payloads.size
    assert_equal "Waiting for approval in Firm", payloads.first[:title]
    assert_equal "2 people or agents are waiting for an owner.", payloads.first[:body]
    assert_equal "/firm/organization/edit", payloads.first[:path]
    assert_no_match(/secret/, payloads.to_json)
  end

  test "with SMTP set, a verified owner is emailed counts and a link, never names" do
    configure_smtp
    @firm.join_requests.create!(user: User.create!(ajent_sub: "3", handle: "applicant-secret", email: "applicant-secret@firm.test"))
    @firm.update_columns(name: "Firm")

    deliveries { perform_enqueued_jobs }

    mail = ActionMailer::Base.deliveries.sole
    assert_equal [ "boss@firm.test" ], mail.to
    assert_equal [ "concourse@firm.test" ], mail.from
    assert_equal "Waiting for approval in Firm", mail.subject
    assert_includes mail.body.to_s, "1 person has asked to join."
    assert_match(%r{https://\S+/firm/organization/edit}, mail.body.to_s)
    assert_no_match(/secret/, mail.body.to_s + mail.subject)
  end

  test "an owner without a verified email is not emailed, and a mail failure does not stop others" do
    configure_smtp
    @boss.update!(email_verified: false)
    @firm.join_requests.create!(user: User.create!(ajent_sub: "3", handle: "a", email: "a@firm.test"))
    deliveries { perform_enqueued_jobs }
    assert_empty ActionMailer::Base.deliveries

    @boss.update!(email_verified: true)
    second = User.create!(ajent_sub: "4", handle: "second", email: "second@firm.test", email_verified: true)
    @firm.memberships.create!(user: second, role: "owner")
    original = ApprovalMailer.method(:waiting)
    calls = 0
    ApprovalMailer.define_singleton_method(:waiting) do |owner, *args, **options|
      calls += 1
      raise Net::OpenTimeout if owner.handle == "boss"
      original.call(owner, *args, **options)
    end
    deliveries { ApprovalAlertJob.perform_now(@firm.id) }
    assert_equal 2, calls
    assert_equal [ [ "second@firm.test" ] ], ActionMailer::Base.deliveries.map(&:to)
  ensure
    ApprovalMailer.singleton_class.remove_method(:waiting) if ApprovalMailer.singleton_class.method_defined?(:waiting, false)
  end

  test "a failing push does not stop the email or the other owners" do
    configure_smtp
    @firm.join_requests.create!(user: User.create!(ajent_sub: "3", handle: "a", email: "a@firm.test"))
    with_payload_send(->(**) { raise ArgumentError, "bad subscription key" }) { perform_enqueued_jobs }
    assert_equal [ [ "boss@firm.test" ] ], ActionMailer::Base.deliveries.map(&:to)
  end

  test "without VAPID keys no push is attempted" do
    Rails.application.config.x.vapid = {}
    @firm.join_requests.create!(user: User.create!(ajent_sub: "3", handle: "a", email: "a@firm.test"))
    assert_empty deliveries { perform_enqueued_jobs }
  end

  test "SMTP settings with YAML punctuation load, and a garbage port falls back to 587" do
    values = { "address" => "smtp.firm.test", "port" => "not-a-port", "username" => "true",
               "password" => "@pass `x a: b %x *x pa ss #x 123456", "from" => "concourse@firm.test" }
    # The credentials reader is the one thing swapped: the template itself is real.
    template = Rails.root.join("config/smtp.yml").read.gsub(/Rails\.app\.creds\.option\(:smtp, :(\w+)\)/) { values.fetch(Regexp.last_match(1)).inspect }
    loaded = YAML.safe_load(ERB.new(template).result, aliases: true).fetch("shared")

    assert_equal values, loaded
    assert_nil Integer(loaded.fetch("port"), 10, exception: false)
  end

  test "without SMTP nothing is emailed, and nothing waiting means no alert at all" do
    Rails.application.config.x.smtp = {}
    @firm.join_requests.create!(user: User.create!(ajent_sub: "3", handle: "a", email: "a@firm.test"))
    assert_equal 1, deliveries { perform_enqueued_jobs }.size
    assert_empty ActionMailer::Base.deliveries

    @firm.join_requests.destroy_all
    assert_empty deliveries { ApprovalAlertJob.perform_now(@firm.id) }
  end

  test "an organization that no longer approves, or is gone, sends nothing" do
    @firm.join_requests.create!(user: User.create!(ajent_sub: "3", handle: "a", email: "a@firm.test"))
    @firm.update!(admission: "automatic")
    assert_empty deliveries { perform_enqueued_jobs }
    assert_empty deliveries { ApprovalAlertJob.perform_now(0) }
  end

  private

  def configure_smtp
    Rails.application.config.x.smtp = { address: "smtp.firm.test", port: 587, username: "u", password: "p", from: "concourse@firm.test" }
  end

  def deliveries
    payloads = []
    with_payload_send(->(message:, **) { payloads << JSON.parse(message, symbolize_names: true) }) { yield }
    payloads
  end

  def with_payload_send(fake)
    original = WebPush.method(:payload_send)
    WebPush.define_singleton_method(:payload_send) { |**options| fake.call(**options) }
    yield
  ensure
    WebPush.define_singleton_method(:payload_send, original)
  end
end
