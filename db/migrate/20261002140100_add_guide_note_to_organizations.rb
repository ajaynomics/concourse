class AddGuideNoteToOrganizations < ActiveRecord::Migration[8.2]
  def change
    add_column :organizations, :guide_note, :text
  end
end
