defmodule Meridian.Repo.Migrations.AddRunEventsDeltaIndex do
  use Ecto.Migration

  # Finds the deltas still kept, so pruning old runs' deltas (Meridian.Runs.prune_deltas/1)
  # doesn't scan every event. Once pruned, a run's deltas leave the index too.
  def change do
    create index(:run_events, [:run_id],
             where: "type = 'message.delta'",
             name: :run_events_deltas_index
           )
  end
end
