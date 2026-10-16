defmodule Meridian.Runs.Worker do
  @moduledoc """
  The Oban job that executes a run: starts its `Meridian.Runs.RunServer` and waits for it to
  finish, so the job lives exactly as long as the run.

  Runs aren't retried. If the RunServer crashes without finishing the run, the run is marked
  failed here; if the whole node dies, `Meridian.Runs.Janitor` fails it once its heartbeat goes
  stale.
  """
  use Oban.Worker, queue: :runs, max_attempts: 1

  require Logger

  alias Meridian.Runs
  alias Meridian.Runs.{Run, RunServer}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    case RunServer.start(run_id) do
      {:ok, pid} -> await(pid, run_id)
      {:error, {:already_started, pid}} -> await(pid, run_id)
    end
  end

  defp await(pid, run_id) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :noproc] ->
        :ok

      {:DOWN, ^ref, :process, ^pid, reason} ->
        Logger.error("RunServer for run #{run_id} exited: #{inspect(reason)}")
        fail_if_active(run_id)
        {:error, reason}
    end
  end

  defp fail_if_active(run_id) do
    with %Run{} = run <- Meridian.Repo.get(Run, run_id) do
      error = %{"code" => "internal_error", "message" => "The run crashed."}
      Runs.finish_run(run, :failed, from: Run.active_statuses(), error: error)
    end
  end
end
