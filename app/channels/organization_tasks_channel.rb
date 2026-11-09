# An organization's task refreshes, for its members only. The stream name is
# signed, but a signature alone would keep working after someone is removed
# or signs out; the membership is checked when they subscribe.
class OrganizationTasksChannel < Turbo::StreamsChannel
  include Turbo::Streams::StreamName

  def subscribed
    name = verified_stream_name_from_params
    if name && current_user.organizations.any? { |organization| stream_name_from([ organization, "tasks" ]) == name }
      stream_from name
    else
      reject
    end
  end
end
