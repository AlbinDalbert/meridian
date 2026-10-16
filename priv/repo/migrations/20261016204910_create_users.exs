defmodule Meridian.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :email, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, ["lower(email)"], name: :users_email_index)
  end
end
