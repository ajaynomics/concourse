class Participation < ApplicationRecord
  belongs_to :project
  belongs_to :agent

  validates :agent_id, uniqueness: { scope: :project_id }
  validate :same_organization

  private

  def same_organization
    return if project.nil? || agent.nil?

    errors.add(:agent, :another_organization) unless project.organization_id == agent.organization_id
  end
end
