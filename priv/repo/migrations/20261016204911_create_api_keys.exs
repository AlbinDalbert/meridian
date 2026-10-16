defmodule Meridian.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :prefix, :text, null: false
      add :token_hash, :binary, null: false
      add :policy, :map, null: false, default: %{}
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:api_keys, [:user_id])
    create unique_index(:api_keys, [:token_hash])
  end
end
