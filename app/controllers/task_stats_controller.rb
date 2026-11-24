class TaskStatsController < ApplicationController
  include NotAVisit

  before_action :require_user, :require_organization, :require_organization_owner

  def show
    no_store
    return unless params.key?(:from) || params.key?(:through)

    @from = date(params[:from])
    @through = date(params[:through])
    now = Time.current.utc
    unless @from && @through && @from <= @through && @through <= now.to_date && @through - @from < 30
      return render :show, status: :unprocessable_content
    end

    @cutoff = [ midnight(@through.next_day), now ].min
    stats = Task::Stats.new(organization: Current.organization, owner: Current.user, from: midnight(@from), before: @cutoff)
    @counts, @summary = ApplicationRecord.while_preventing_writes { [ stats.message_counts, stats.summary ] }
  end

  private

  def date(value)
    Date.iso8601(value) if value.is_a?(String) && value.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/)
  rescue Date::Error
    nil
  end

  def midnight(day)
    Time.utc(day.year, day.month, day.day)
  end

  def live_updates?
    false
  end
end
