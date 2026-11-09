# Cross-process capacity is a database lease, not the web process's Waiters.
# Expiry frees only observation/capacity; it never reclaims a mutation receipt.
class RelayNetworkSlot < ApplicationRecord
  LIMITS = { "dispatch" => 2, "follow" => 1 }.freeze
  MAX_LEASE = { "dispatch" => 15.seconds, "follow" => 60.seconds }.freeze
  belongs_to :organization, optional: true

  def self.acquire(kind:, organization:, holder:, now: Time.current)
    kind = kind.to_s
    raise ArgumentError unless LIMITS.key?(kind) && holder.is_a?(String) && holder.present?
    # Schema loads don't run migration seed SQL. Deterministic IDs and an
    # insert-ignore preserve active holders, even across concurrent boots.
    rows = (1..12).map { |id| { id: id, kind: id <= 8 ? "dispatch" : "follow" } }
    insert_all(rows, unique_by: :id)

    transaction do
      # tenancy-ok: shared, content-free capacity records arbitrate all tenants.
      slots = where(kind: kind).lock.order(:id).to_a
      active = slots.select { |slot| slot.expires_at && slot.expires_at > now }
      return if active.count { |slot| slot.organization_id == organization.id } >= LIMITS.fetch(kind)
      slot = (slots - active).first
      return unless slot
      # SQLite's lock is database-wide; the compare-and-set also fences a
      # contender that observed the same expired row before gaining the lock.
      eligible = where(id: slot.id).where("expires_at IS NULL OR expires_at <= ?", now)
      changed = eligible.update_all(organization_id: organization.id, holder: holder, expires_at: now + MAX_LEASE.fetch(kind))
      slot.reload if changed == 1
    end
  end

  def held_by?(owner, now: Time.current)
    holder == owner && expires_at && expires_at > now
  end

  def renew(owner, now: Time.current)
    changed = self.class.where(id: id, holder: owner).where("expires_at > ?", now)
      .update_all(expires_at: now + MAX_LEASE.fetch(kind))
    reload if changed == 1
    changed == 1
  end

  def release(owner)
    # A late holder cannot release a successor's slot.
    self.class.where(id: id, holder: owner).update_all(organization_id: nil, holder: nil, expires_at: nil)
  end
end
