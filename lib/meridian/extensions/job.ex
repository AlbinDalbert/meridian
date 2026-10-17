defmodule Meridian.Extensions.Job do
  @moduledoc """
  A background job an extension queued with `meridian.jobs.enqueue`: calls
  `M.jobs[name](args, ctx)` with the latest version of the extension's script, and the context
  of the call that queued it.

  A job that fails (the script raised, or timed out) is retried. One whose extension or job
  function is gone is cancelled.
  """
  use Oban.Worker, queue: :extensions, max_attempts: 3

  alias Meridian.Extensions
  alias Meridian.Extensions.Context

  @doc "A job for `extension_id`'s `name` job. With a `unique` key, it's unique while pending."
  def new(extension_id, name, args, %Context{} = ctx, unique, delay) do
    job_args = %{
      "extension_id" => extension_id,
      "job" => name,
      "args" => args,
      "ctx" => Context.to_job(ctx)
    }

    delay_opts = if is_number(delay) and delay > 0, do: [schedule_in: round(delay)], else: []

    if is_nil(unique) do
      new(job_args, delay_opts)
    else
      unique_opts = [keys: [:extension_id, :job, :unique], states: :incomplete, period: :infinity]
      new(Map.put(job_args, "unique", unique), [unique: unique_opts] ++ delay_opts)
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"extension_id" => id, "job" => name} = args}) do
    Extensions.run_job(id, name, args["args"], Context.from_job(args["ctx"]))
  end
end
