defmodule Meridian.Repo.Migrations.AddTagsToThreads do
  use Ecto.Migration

  def change do
    alter table(:threads) do
      add :tags, {:array, :text}, null: false, default: []
    end

    # For filtering threads by tag (`tags @> ARRAY[...]`).
    create index(:threads, [:tags], using: :gin)
  end
end
