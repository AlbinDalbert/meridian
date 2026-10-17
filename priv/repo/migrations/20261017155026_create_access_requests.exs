defmodule Meridian.Repo.Migrations.CreateAccessRequests do
  use Ecto.Migration

  def change do
    create table(:access_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :text, null: false
      add :name, :text
      # pending, snoozed, or rejected. Accepted requests are deleted: the user exists then.
      add :status, :text, null: false, default: "pending"
      add :status_changed_at, :utc_datetime_usec
      # Asking again doesn't add a request; it bumps this one (see Meridian.AccessRequests).
      add :requested_at, :utc_datetime_usec, null: false
      add :times_requested, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:access_requests, ["lower(email)"], name: :access_requests_email_index)
    create index(:access_requests, [:status, :requested_at])
  end
end
