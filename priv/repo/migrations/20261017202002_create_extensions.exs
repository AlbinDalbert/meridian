defmodule Meridian.Repo.Migrations.CreateExtensions do
  use Ecto.Migration

  def change do
    create table(:extensions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      # The extension's Lua script (see Meridian.Extensions.Script).
      add :source, :text, null: false
      # Who it belongs to; null for global extensions, which every user can use.
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:extensions, [:name],
             where: "user_id IS NULL",
             name: :extensions_global_name_index
           )

    create unique_index(:extensions, [:user_id, :name],
             where: "user_id IS NOT NULL",
             name: :extensions_user_id_name_index
           )

    # Personas now name the extensions they enable by id. The built-in extensions they named
    # are gone, and so are their jobs.
    execute "UPDATE personas SET extensions = '{}'", ""
    execute "DELETE FROM oban_jobs WHERE worker = 'Meridian.Ext.Title.Worker'", ""
  end
end
