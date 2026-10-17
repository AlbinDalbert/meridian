defmodule Meridian.Runs do
  @moduledoc """
  Runs and their event logs.

  A run is executed by a `Meridian.Runs.RunServer`, started by the `Meridian.Runs.Worker` Oban
  job. Everything that happens in a run is an event (`Meridian.Runs.Event`): persisted to
  `run_events`, then broadcast on PubSub so subscribers see it immediately.

  ## PubSub

    * `"run:<id>"` and `"thread:<id>"` receive `{:run_event, %Event{}}` for every event.
    * `"runs"` receives `{:run_updated, %Run{}}` whenever a run's status changes (for the admin
      console).

  Ending a run (`finish_run/3`, however the run ends) fires the `run_end` hook of the
  extensions the run's persona enables.

  Subscribers that need every event (SSE, the admin run view) subscribe first, then replay the
  persisted events with `list_events/2`, dropping live events they already replayed (by `seq`).
  """
  import Ecto.Query

  require Logger

  alias Meridian.Accounts.User
  alias Meridian.Extensions.Context
  alias Meridian.{Extensions, Repo}
  alias Meridian.Runs.{Event, Run}
  alias Meridian.Threads.{Message, Thread}

  @pubsub Meridian.PubSub

  ## Queries

  def get_run!(id), do: Repo.get!(Run, id)

  @doc "Gets a run with its thread, the thread's user, and the user message preloaded."
  def get_run_details!(id) do
    Run |> Repo.get!(id) |> Repo.preload([:user_message, thread: :user])
  end

  @doc "Gets one of `user`'s runs, or nil."
  def get_user_run(%User{id: user_id}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.one(
        from r in Run,
          join: t in assoc(r, :thread),
          where: r.id == ^id and t.user_id == ^user_id
      )
    else
      :error -> nil
    end
  end

  @doc "A thread's runs, newest first."
  def list_runs(%Thread{id: thread_id}) do
    Repo.all(from r in Run, where: r.thread_id == ^thread_id, order_by: [desc: r.id])
  end

  @doc "The most recent runs across all users, newest first, with thread and user preloaded."
  def list_recent_runs(limit \\ 50) do
    Repo.all(from r in Run, order_by: [desc: r.id], limit: ^limit, preload: [thread: :user])
  end

  @doc "The thread's active (queued, running, or awaiting approval) run, or nil."
  def get_active_run(%Thread{id: thread_id}) do
    Repo.one(
      from r in Run, where: r.thread_id == ^thread_id and r.status in ^Run.active_statuses()
    )
  end

  @doc "A run's persisted events with `seq` greater than `after_seq`, in order."
  def list_events(%Run{id: run_id}, after_seq \\ 0) do
    Repo.all(from e in Event, where: e.run_id == ^run_id and e.seq > ^after_seq, order_by: e.seq)
  end

  ## Subscriptions

  def subscribe(%Run{id: run_id}), do: Phoenix.PubSub.subscribe(@pubsub, run_topic(run_id))
  def unsubscribe(%Run{id: run_id}), do: Phoenix.PubSub.unsubscribe(@pubsub, run_topic(run_id))

  def subscribe_thread(%Thread{id: thread_id}),
    do: Phoenix.PubSub.subscribe(@pubsub, thread_topic(thread_id))

  def subscribe_all, do: Phoenix.PubSub.subscribe(@pubsub, "runs")

  defp run_topic(run_id), do: "run:" <> run_id
  defp thread_topic(thread_id), do: "thread:" <> thread_id

  # Cancel requests go to the RunServer on its own topic, wherever in the cluster it runs.
  @doc false
  def subscribe_control(run_id), do: Phoenix.PubSub.subscribe(@pubsub, control_topic(run_id))
  defp control_topic(run_id), do: "run_control:" <> run_id

  ## Cancellation

  @doc """
  Cancels a run. A queued run is cancelled right away; a running run is asked to stop, and
  its `RunServer` saves the partial reply and emits `run.cancelled`. Cancelling a finished run
  does nothing. Returns the run as it is now.
  """
  def cancel_run(%Run{status: :queued} = run) do
    case finish_run(run, :cancelled, from: [:queued]) do
      {:ok, run, _message} -> {:ok, run}
      {:error, :not_active} -> run |> Repo.reload!() |> cancel_run()
    end
  end

  def cancel_run(%Run{} = run) do
    if not Run.finished?(run) do
      Phoenix.PubSub.broadcast(@pubsub, control_topic(run.id), {:cancel_run, run.id})
    end

    {:ok, run}
  end

  ## Lifecycle (used by the RunServer and the janitor)

  @doc false
  # Moves a queued run to running and emits `run.started`. Returns the run and that event.
  def start_run(run_id) do
    now = DateTime.utc_now()

    Repo.transact(fn ->
      case Repo.update_all(
             from(r in Run, where: r.id == ^run_id and r.status == :queued, select: r),
             set: [status: :running, started_at: now, heartbeat_at: now, updated_at: now]
           ) do
        {1, [run]} ->
          {:ok, event} = insert_event(run, next_seq(run), "run.started", %{"model" => run.model})
          {:ok, {run, event}}

        {0, _} ->
          {:error, :not_queued}
      end
    end)
    |> case do
      {:ok, {run, event}} ->
        broadcast_event(run, event)
        broadcast_run(run)
        {:ok, run, event}

      error ->
        error
    end
  end

  @doc false
  # Records that the run's RunServer is alive. Fails if the run is no longer running (e.g. the
  # janitor gave up on it).
  def heartbeat(%Run{id: run_id}) do
    case Repo.update_all(
           from(r in Run, where: r.id == ^run_id and r.status == :running),
           set: [heartbeat_at: DateTime.utc_now()]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_running}
    end
  end

  @doc false
  # Persists and broadcasts an event. Only the run's RunServer appends events while the run is
  # running, so it owns `seq`.
  def append_event(%Run{} = run, seq, type, payload) do
    with {:ok, event} <- insert_event(run, seq, type, payload) do
      broadcast_event(run, event)
      {:ok, event}
    end
  end

  @doc false
  # Ends an active run, in one transaction: sets the final status, optionally saves the
  # assistant message, and appends `message.completed` (if there is a message) and the
  # terminal event (`run.completed`, `run.failed`, or `run.cancelled`).
  #
  # Options:
  #   * `:from` - statuses the run may be in (default: running)
  #   * `:seq` - the last seq used by the caller; read from the database if not given
  #   * `:message` - assistant message attributes (content, metadata, usage)
  #   * `:usage`, `:error` - stored on the run and put in the terminal event
  def finish_run(%Run{} = run, status, opts \\ [])
      when status in [:completed, :failed, :cancelled] do
    from = Keyword.get(opts, :from, [:running])
    now = DateTime.utc_now()

    changes = [
      status: status,
      finished_at: now,
      updated_at: now,
      usage: opts[:usage],
      error: opts[:error]
    ]

    Repo.transact(fn ->
      case Repo.update_all(
             from(r in Run, where: r.id == ^run.id and r.status in ^from, select: r),
             set: changes
           ) do
        {1, [run]} ->
          seq = Keyword.get_lazy(opts, :seq, fn -> next_seq(run) - 1 end)
          {message, events} = insert_final_message(run, opts[:message], seq)
          seq = seq + length(events) + 1
          {:ok, terminal} = insert_event(run, seq, "run.#{status}", terminal_payload(run))
          touch_thread(run.thread_id, now)
          {:ok, {run, message, events ++ [terminal]}}

        {0, _} ->
          {:error, :not_active}
      end
    end)
    |> case do
      {:ok, {run, message, events}} ->
        Enum.each(events, &broadcast_event(run, &1))
        broadcast_run(run)
        run_end(run)
        {:ok, run, message}

      error ->
        error
    end
  end

  # Every way a run ends comes through finish_run, so this fires once per run, after commit.
  defp run_end(run) do
    ctx = Context.for_run(run)
    Extensions.notify(Extensions.enabled(ctx.persona), :run_end, [run], ctx)
  end

  defp insert_final_message(_run, nil, _seq), do: {nil, []}

  defp insert_final_message(run, attrs, seq) do
    message =
      Repo.insert!(%Message{
        thread_id: run.thread_id,
        run_id: run.id,
        role: "assistant",
        content: Map.fetch!(attrs, :content),
        metadata: Map.get(attrs, :metadata, %{}),
        usage: Map.get(attrs, :usage)
      })

    {:ok, event} =
      insert_event(run, seq + 1, "message.completed", %{"message" => Message.to_map(message)})

    {message, [event]}
  end

  defp terminal_payload(%Run{status: :completed, usage: usage}), do: %{"usage" => usage}
  defp terminal_payload(%Run{status: :failed, error: error}), do: %{"error" => error}
  defp terminal_payload(%Run{status: :cancelled}), do: %{}

  @doc """
  Fails runs whose RunServer stopped sending heartbeats (e.g. the node running it died), so
  their threads are free again. Returns how many runs were failed.
  """
  def fail_stale_runs(stale_after_ms \\ config(:stale_after, :timer.seconds(60))) do
    cutoff = DateTime.add(DateTime.utc_now(), -stale_after_ms, :millisecond)

    stale =
      Repo.all(from r in Run, where: r.status == :running and r.heartbeat_at < ^cutoff, select: r)

    Enum.count(stale, fn run ->
      error = %{"code" => "interrupted", "message" => "The run was interrupted."}

      case finish_run(run, :failed, error: error) do
        {:ok, _run, _message} ->
          Logger.warning("Failed stale run #{run.id}")
          true

        {:error, :not_active} ->
          false
      end
    end)
  end

  defp insert_event(run, seq, type, payload) do
    Repo.insert(%Event{run_id: run.id, seq: seq, type: type, payload: payload})
  end

  defp next_seq(%Run{id: run_id}) do
    Repo.one(from e in Event, where: e.run_id == ^run_id, select: coalesce(max(e.seq), 0)) + 1
  end

  defp touch_thread(thread_id, now) do
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [updated_at: now])
  end

  defp broadcast_event(run, event) do
    Phoenix.PubSub.broadcast(@pubsub, run_topic(run.id), {:run_event, event})
    Phoenix.PubSub.broadcast(@pubsub, thread_topic(run.thread_id), {:run_event, event})
  end

  @doc false
  def broadcast_run(run), do: Phoenix.PubSub.broadcast(@pubsub, "runs", {:run_updated, run})

  @doc false
  def config(key, default) do
    :meridian |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
