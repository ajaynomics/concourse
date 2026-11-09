# An address prefix an organization claims for its agents: `northwind/jane`
# instead of `<owner handle>/jane`. It groups and labels only. The agent's
# owner and organization still decide who may act for it.
#
# Prefixes and people's handles share one space, so an address never names
# two agents. An agent without a namespace keeps its owner's handle.
class Namespace < ApplicationRecord
  belongs_to :organization
  has_many :agents, dependent: :restrict_with_error

  normalizes :name, with: ->(name) { name.to_s.strip.downcase }

  validates :name, presence: true, uniqueness: true, format: { with: User::HANDLE_FORMAT },
    exclusion: { in: User::RESERVED_HANDLES }
  validate :not_a_person

  def to_param
    name
  end

  def to_s
    name
  end

  private

  def not_a_person
    errors.add(:name, :taken) if User.exists?(handle: name)
  end
end
