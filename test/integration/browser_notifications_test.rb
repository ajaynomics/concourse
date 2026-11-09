require "test_helper"

class BrowserNotificationsTest < ActionDispatch::IntegrationTest
  setup do
    @previous_vapid = Rails.application.config.x.vapid
    key = WebPush.generate_key
    Rails.application.config.x.vapid = { subject: "mailto:notifications@example.test", public_key: key.public_key, private_key: key.private_key }
    @user = User.create!(ajent_sub: "notifications-owner", handle: "notifications-owner", email: "notifications@example.test", organizations: [ Organization.default ])
    sign_in_via_ajent(subject: @user.ajent_sub, email: @user.email, name: "Notifications Owner")
    @endpoint = "https://fcm.googleapis.com/fcm/send/notifications-browser"
  end

  teardown { Rails.application.config.x.vapid = @previous_vapid }

  test "visiting offers an optional per-browser setting without subscribing" do
    assert_no_difference -> { PushSubscription.count } do
      get organization_root_path(Organization.default)
    end

    assert_select "button[data-push-target=toggle][aria-pressed=false]"
    assert_select "[data-push-target=status][role=status]", text: I18n.t("layouts.application.notifications.disabled")
    assert_select "[data-controller=push][data-push-endpoint-value='']"
  end

  test "unsubscribing clears this session's endpoint and leaves another browser alone" do
    other = @user.push_subscriptions.create!(endpoint: "https://fcm.googleapis.com/fcm/send/other-browser", p256dh_key: "p", auth_key: "a")
    post push_subscription_path, params: { endpoint: @endpoint, keys: { p256dh: "p", auth: "a" } }, as: :json
    assert_response :created
    get organization_root_path(Organization.default)
    assert_select "[data-controller=push][data-push-endpoint-value=?]", @endpoint

    delete push_subscription_path, params: { endpoint: @endpoint }, as: :json
    assert_response :no_content
    assert_not @user.push_subscriptions.exists?(endpoint: @endpoint)
    assert PushSubscription.exists?(other.id)
    get organization_root_path(Organization.default)
    assert_select "[data-controller=push][data-push-endpoint-value='']"
  end

  test "one person cannot turn off another person's browser" do
    other_user = User.create!(ajent_sub: "other-notifications-owner", handle: "other-notifications-owner", organizations: [ Organization.default ])
    other = other_user.push_subscriptions.create!(endpoint: "https://fcm.googleapis.com/fcm/send/other-owner", p256dh_key: "p", auth_key: "a")

    delete push_subscription_path, params: { endpoint: other.endpoint }, as: :json

    assert_response :no_content
    assert PushSubscription.exists?(other.id)
  end

  test "one person cannot take over another person's browser subscription; re-subscribing your own works" do
    other_user = User.create!(ajent_sub: "other-notifications-owner", handle: "other-notifications-owner", organizations: [ Organization.default ])
    other = other_user.push_subscriptions.create!(endpoint: "https://fcm.googleapis.com/fcm/send/other-owner", p256dh_key: "p", auth_key: "a")

    post push_subscription_path, params: { endpoint: other.endpoint, keys: { p256dh: "mine", auth: "mine" } }, as: :json

    assert_response :unprocessable_content
    assert_equal [ other_user, "p" ], other.reload.then { |subscription| [ subscription.user, subscription.p256dh_key ] }

    2.times do |index|
      post push_subscription_path, params: { endpoint: @endpoint, keys: { p256dh: "p#{index}", auth: "a" } }, as: :json
      assert_response :created
    end
    assert_equal "p1", @user.push_subscriptions.sole.p256dh_key
  end

  test "a public key alone does not offer a setting that the server cannot enable" do
    Rails.application.config.x.vapid = { public_key: "incomplete-installation" }
    get organization_root_path(Organization.default)

    assert_select "[data-controller=push][data-push-key-value='']"
    assert_select "[data-push-target=status]", text: I18n.t("layouts.application.notifications.unconfigured")
    assert_no_difference -> { PushSubscription.count } do
      post push_subscription_path, params: { endpoint: @endpoint, keys: { p256dh: "p", auth: "a" } }, as: :json
    end
    assert_response :not_found
  end
end
