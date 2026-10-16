defmodule Meridian.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14)

  # Drops the Oban tables entirely.
  def down, do: Oban.Migration.down(version: 1)
end
