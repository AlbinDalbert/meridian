defmodule Meridian.Repo.Migrations.CreatePersonas do
  use Ecto.Migration

  def change do
    create table(:personas, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :slug, :text, null: false
      add :name, :text, null: false
      add :system_prompt, :text, null: false, default: ""
      add :model, :text, null: false
      add :params, :map, null: false, default: %{}
      add :extensions, :map, null: false, default: %{}
      add :is_default, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:personas, [:user_id, :slug])

    # At most one default persona per user.
    create unique_index(:personas, [:user_id],
             where: "is_default",
             name: :personas_one_default_per_user_index
           )
  end
end
