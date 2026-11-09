class AddMachineClientsToOrganizations < ActiveRecord::Migration[8.2]
  def change
    # Unattended credentials, operator-bound or joined through /connect, work
    # only in an organization whose owner turned them on.
    add_column :organizations, :machine_clients, :boolean, null: false, default: false

    # A one-time hand-over from operator configuration to data: the
    # organizations listed in this variable keep machine clients the moment
    # this deploys. The app no longer reads it, so it is read here, directly,
    # at migrate time; afterwards owners decide.
    up_only do
      slugs = ENV["CONCOURSE__MACHINE_CLIENT_ORGANIZATIONS"].to_s.split(",").map(&:strip).compact_blank
      if slugs.any?
        execute "UPDATE organizations SET machine_clients = #{quoted_true} WHERE slug IN (#{slugs.map { |slug| quote(slug) }.join(", ")})"
      end
    end
  end
end
