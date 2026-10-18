defmodule Meridian.Runs.EventPruner do
  @moduledoc """
  Hourly Oban job (see the `Oban.Plugins.Cron` config) that deletes the `message.delta` events
  of runs that finished more than `:delta_retention` ago (see `Meridian.Runs.prune_deltas/1`).
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    Meridian.Runs.prune_deltas()
    :ok
  end
end
