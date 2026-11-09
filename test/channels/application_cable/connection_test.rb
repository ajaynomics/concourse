require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  KEY = Rails.application.config.session_options[:key]

  setup { @kim = User.create!(ajent_sub: "1", handle: "kim") }

  test "a signed-in person connects" do
    cookies.encrypted[KEY] = { value: { "user_id" => @kim.id, "signed_in_at" => Time.current.iso8601 } }

    connect
    assert_equal @kim, connection.current_user
  end

  test "no session, or an expired one, is refused" do
    assert_reject_connection { connect }

    cookies.encrypted[KEY] = { value: { "user_id" => @kim.id, "signed_in_at" => 13.hours.ago.iso8601 } }
    assert_reject_connection { connect }
  end
end
