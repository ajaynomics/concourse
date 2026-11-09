namespace :analytics do
  desc "Page analytics from Ahoy: visits, people, and views by page (DAYS=7)"
  task summary: :environment do
    since = ENV.fetch("DAYS", "7").to_i.days.ago
    visits = Ahoy::Visit.human.where(started_at: since..)

    puts "Since #{since.to_date}: #{visits.count} visits, #{visits.distinct.count(:user_id)} signed-in people"
    Ahoy::Event.views_by_page(since: since).each do |page, count|
      puts format("%6d  %s", count, page)
    end
  end
end
