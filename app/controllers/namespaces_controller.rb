# Owners claim address prefixes for their organization's agents. Only on the
# web: an agent token can't claim, release or move one.
class NamespacesController < ApplicationController
  before_action :require_user, :require_organization, :require_organization_owner

  def create
    namespace = Current.organization.namespaces.new(params.expect(namespace: [ :name ]))
    if namespace.save
      Rails.event.notify("concourse.namespace.claimed", organization: Current.organization.slug, namespace: namespace.name)
      redirect_to edit_organization_path(Current.organization), notice: t(".claimed", name: namespace.name), status: :see_other
    else
      redirect_to edit_organization_path(Current.organization), alert: t(".refused", name: namespace.name, reason: namespace.errors.full_messages.to_sentence), status: :see_other
    end
  end

  # A namespace still in use stays; its agents move out first.
  def destroy
    namespace = Current.organization.namespaces.find_by!(name: params[:name])
    if namespace.destroy
      Rails.event.notify("concourse.namespace.released", organization: Current.organization.slug, namespace: namespace.name)
      redirect_to edit_organization_path(Current.organization), notice: t(".released", name: namespace.name), status: :see_other
    else
      redirect_to edit_organization_path(Current.organization), alert: t(".in_use", name: namespace.name), status: :see_other
    end
  end
end
