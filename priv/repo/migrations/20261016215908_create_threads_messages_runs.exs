defmodule Meridian.Repo.Migrations.CreateThreadsMessagesRuns do
  use Ecto.Migration

  def change do
    create table(:threads, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :persona_id, references(:personas, type: :binary_id, on_delete: :nilify_all)
      add :title, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:threads, [:user_id, :updated_at])
    create index(:threads, [:persona_id])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :thread_id, references(:threads, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :text, null: false
      add :content, {:array, :map}, null: false, default: []
      add :metadata, :map, null: false, default: %{}
      add :usage, :map

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Ids are UUIDv7, so ordering by id is ordering by creation time.
    create index(:messages, [:thread_id, :id])

    create table(:runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :thread_id, references(:threads, type: :binary_id, on_delete: :delete_all), null: false

      add :user_message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :status, :text, null: false
      add :persona_snapshot, :map, null: false
      add :model, :text, null: false
      add :usage, :map
      add :error, :map
      add :heartbeat_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:runs, [:thread_id, :id])
    create index(:runs, [:status], where: "status IN ('queued', 'running', 'awaiting_approval')")

    # One active run per thread.
    create unique_index(:runs, [:thread_id],
             where: "status IN ('queued', 'running', 'awaiting_approval')",
             name: :runs_one_active_per_thread_index
           )

    alter table(:messages) do
      add :run_id, references(:runs, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:messages, [:run_id])

    create table(:run_events, primary_key: false) do
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), primary_key: true

      add :seq, :integer, primary_key: true
      add :type, :text, null: false
      add :payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end
end
