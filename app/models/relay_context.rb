class RelayContext < ApplicationRecord
  belongs_to :organization
  belongs_to :caller_agent, class_name: "Agent"
  belongs_to :recipient_agent, class_name: "Agent"

  SCOPE_FIELDS = %w[organization_id caller_agent_id recipient_agent_id generation public_context_id].freeze
  validates :generation, :public_context_id, :content_changed_at, presence: true
  validate :same_organization, on: :create
  validate :immutable_mapping, on: :update

  def self.map!(caller:, recipient:, generation:, public_context_id: nil, native_context_id: nil)
    recipient.with_lock do
      raise Agent::Unadmitted unless caller.admitted? && recipient.admitted? && caller.organization_id == recipient.organization_id
      scope = where(organization_id: recipient.organization_id, caller_agent_id: caller.id, recipient_agent_id: recipient.id, generation: generation)
      mapping = scope.find_by(public_context_id: public_context_id) if public_context_id.present?
      if mapping
        mapping.bind_native!(native_context_id) if native_context_id.present?
        mapping.update!(content_changed_at: Time.current)
        return mapping
      end
      create!(organization: recipient.organization, caller_agent: caller, recipient_agent: recipient, generation: generation,
        public_context_id: public_context_id.presence || SecureRandom.uuid, native_context_id: native_context_id,
        content_changed_at: Time.current)
    end
  end

  def bind_native!(id)
    with_lock do
      raise RelayDelivery::Mismatch if id.blank? || (native_context_id.present? && native_context_id != id)
      update!(native_context_id: id, content_changed_at: Time.current)
    end
    self
  end

  private

  def same_organization
    errors.add(:base, :across_organizations) if [ caller_agent, recipient_agent ].compact.any? { |agent| agent.organization_id != organization_id }
  end

  def immutable_mapping
    errors.add(:base, "immutable context scope") if SCOPE_FIELDS.any? { |field| will_save_change_to_attribute?(field) }
    if native_context_id_in_database.present? && will_save_change_to_native_context_id?
      errors.add(:native_context_id, "cannot be remapped")
    end
  end
end
