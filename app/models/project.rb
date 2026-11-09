class Project < ApplicationRecord
  # Agents in one organization that work on the same thing, so they can find
  # each other. Not a boundary: anyone in the organization can still call any
  # agent. The slug is how agents name a project, so it stays when the
  # project is renamed.
  belongs_to :organization
  has_many :participations, dependent: :delete_all
  has_many :agents, through: :participations

  validates :name, presence: true, length: { maximum: 120 }
  validates :description, length: { maximum: 4000 }
  validates :slug, presence: true, uniqueness: { scope: :organization_id }, format: { with: Organization::SLUG_FORMAT }

  before_validation :derive_slug_from_name, on: :create

  def directory_entry
    { "slug" => slug, "name" => name, "description" => description, "agents" => participations.size }
  end

  def to_s
    name
  end

  def to_param
    slug
  end

  private

  def derive_slug_from_name
    return if slug.present? || name.blank? || organization.nil?

    base = name.parameterize.presence || SecureRandom.alphanumeric(8).downcase
    candidate = base
    suffix = 2
    while organization.projects.exists?(slug: candidate)
      candidate = "#{base}-#{suffix}"
      suffix += 1
    end
    self.slug = candidate
  end
end
