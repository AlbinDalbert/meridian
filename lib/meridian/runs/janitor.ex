defmodule Meridian.Runs.Janitor do
  @moduledoc """
  Periodic Oban job (see the `Oban.Plugins.Cron` config) that fails runs nothing will finish:
  running runs whose RunServer has stopped heartbeating (e.g. the node running it was
  restarted), and queued runs whose job is gone (see `Meridian.Runs.fail_stale_runs/1`).
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    Meridian.Runs.fail_stale_runs()
    :ok
  end
end
