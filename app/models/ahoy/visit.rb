# One arrival at the pages people use. Anonymous until sign-in binds the
# user to it.
class Ahoy::Visit < ApplicationRecord
  self.table_name = "ahoy_visits"

  has_many :events, class_name: "Ahoy::Event", inverse_of: :visit
  belongs_to :user, optional: true

  # Crawlers are recorded, flagged; counts of people go through here.
  scope :human, -> { where(bot: false) }
end
