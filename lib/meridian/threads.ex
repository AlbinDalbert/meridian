defmodule Meridian.Threads do
  @moduledoc """
  Threads and their messages: the server-owned conversations of the native API.

  Sending a message creates a queued run (`Meridian.Runs.Run`) that generates the reply in the
  background, independently of the client that sent it.
  """
  import Ecto.Query

  alias Meridian.Accounts.ApiKey.Policy
  alias Meridian.Accounts.User
  alias Meridian.{Extensions, Agents, Repo}
  alias Meridian.Extensions.Context
  alias Meridian.Agents.Agent
  alias Meridian.Runs.{Run, Worker}
  alias Meridian.Threads.{Message, Thread}

  @default_page_size 50
  @max_page_size 200

  ## Threads

  @doc """
  How much `user` uses Meridian, without anything they said: their number of threads,
  messages, and runs, the tokens their runs used (`tokens_in` / `tokens_out`, from the
  upstream's usage reports), and when they were last active. For the admin console, which
  never shows conversations.
  """
  def activity(%User{id: user_id}) do
    threads = from t in Thread, where: t.user_id == ^user_id

    %{thread_count: thread_count, last_active_at: last_active_at} =
      Repo.one(
        from t in threads,
          select: %{thread_count: count(t.id), last_active_at: max(t.updated_at)}
      )

    message_count =
      Repo.aggregate(from(m in Message, join: t in ^threads, on: m.thread_id == t.id), :count)

    runs =
      Repo.one(
        from r in Run,
          join: t in ^threads,
          on: r.thread_id == t.id,
          select: %{
            run_count: count(r.id),
            tokens_in: type(sum(fragment("(?->>'prompt_tokens')::bigint", r.usage)), :integer),
            tokens_out:
              type(sum(fragment("(?->>'completion_tokens')::bigint", r.usage)), :integer)
          }
      )

    %{
      thread_count: thread_count,
      message_count: message_count,
      run_count: runs.run_count,
      tokens_in: runs.tokens_in || 0,
      tokens_out: runs.tokens_out || 0,
      last_active_at: last_active_at
    }
  end

  @doc """
  A user's threads, most recently active first. With `tags: [...]`, only the threads that have
  all of them.
  """
  def list_threads(%User{id: user_id}, opts \\ []) do
    query =
      from t in Thread,
        where: t.user_id == ^user_id,
        order_by: [desc: t.updated_at],
        limit: ^page_size(opts[:limit]),
        preload: :agent

    query =
      case opts[:tags] do
        [_ | _] = tags -> where(query, [t], fragment("? @> ?", t.tags, ^tags))
        _ -> query
      end

    Repo.all(query)
  end

  @doc "Gets one of `user`'s threads (agent preloaded), or nil."
  def get_user_thread(%User{id: user_id}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.one(from t in Thread, where: t.id == ^id and t.user_id == ^user_id, preload: :agent)
    else
      :error -> nil
    end
  end

  def get_thread!(id), do: Thread |> Repo.get!(id) |> Repo.preload([:agent, :user])

  @doc """
  Creates a thread for `user`. `attrs["agent"]` is an agent model id (`meridian/<slug>`) or
  slug; without one the key's default agent is used (see
  `Meridian.Agents.resolve_agent/3`).
  """
  def create_thread(%User{} = user, %Policy{} = policy, attrs) do
    slug = agent_slug(attrs["agent"])

    with {:ok, agent} <- Agents.resolve_agent(user, policy, slug),
         {:ok, thread} <-
           %Thread{user_id: user.id, agent_id: agent.id, agent: agent}
           |> Thread.changeset(attrs)
           |> Repo.insert() do
      notify_extensions(:thread_created, thread, agent)
      {:ok, thread}
    end
  end

  @doc """
  Updates a thread's title and tags and, if `attrs[\"agent\"]` is given, its agent. The thread
  keeps its `updated_at`: editing it isn't activity, so it doesn't move up the list.
  """
  def update_thread(%Thread{} = thread, %Policy{} = policy, attrs) do
    agent =
      case Map.fetch(attrs, "agent") do
        {:ok, agent} when is_binary(agent) ->
          Agents.resolve_agent(%User{id: thread.user_id}, policy, agent_slug(agent))

        _ ->
          {:ok, thread.agent}
      end

    with {:ok, agent} <- agent,
         {:ok, thread} <-
           thread
           |> Thread.changeset(attrs)
           |> Ecto.Changeset.put_change(:agent_id, agent && agent.id)
           |> Ecto.Changeset.force_change(:updated_at, thread.updated_at)
           |> Repo.update() do
      {:ok, %{thread | agent: agent}}
    end
  end

  @doc """
  Sets a thread's title without touching anything else (its `updated_at` included, so the
  thread doesn't move up the list). With `only_if_untitled: true`, a title that is already
  set (e.g. by the user) is left alone and `{:error, :titled}` is returned.
  """
  def set_title(thread_id, title, opts \\ []) when is_binary(title) do
    query = from t in Thread, where: t.id == ^thread_id
    query = if opts[:only_if_untitled], do: where(query, [t], is_nil(t.title)), else: query

    case Repo.update_all(query, set: [title: title]) do
      {1, _} ->
        :ok

      {0, _} ->
        if Repo.exists?(from t in Thread, where: t.id == ^thread_id),
          do: {:error, :titled},
          else: {:error, :not_found}
    end
  end

  @doc "Deletes a thread with its messages and runs. Fails while the thread has an active run."
  def delete_thread(%Thread{} = thread) do
    if Repo.exists?(
         from r in Run, where: r.thread_id == ^thread.id and r.status in ^Run.active_statuses()
       ) do
      {:error, :run_active}
    else
      %{agent: agent} = thread = Repo.preload(thread, :agent)

      with {:ok, thread} <- Repo.delete(thread) do
        notify_extensions(:thread_deleted, thread, agent)
        {:ok, thread}
      end
    end
  end

  @doc """
  Copies a thread for its user, with the same title, tags and agent and copies of its messages up to
  and including `through_id` (all of them if nil). The copies keep their content and times but
  belong to no run. Returns `{:error, :not_found}` if `through_id` isn't one of the thread's
  messages.
  """
  def fork_thread(%Thread{} = thread, through_id) do
    with {:ok, messages} <- messages_through(thread, through_id),
         {:ok, fork} <- insert_fork(thread, messages) do
      %{agent: agent} = fork = Repo.preload(fork, :agent)
      notify_extensions(:thread_created, fork, agent)
      {:ok, fork}
    end
  end

  defp messages_through(thread, nil), do: {:ok, list_all_messages(thread)}

  defp messages_through(thread, through_id) do
    with %Message{id: through_id} <- get_thread_message(thread, through_id) do
      {:ok, Enum.filter(list_all_messages(thread), &(&1.id <= through_id))}
    end
  end

  # Ids are generated in insertion order, so the copies keep the originals' order.
  defp insert_fork(thread, messages) do
    Repo.transact(fn ->
      fork =
        Repo.insert!(%Thread{
          user_id: thread.user_id,
          agent_id: thread.agent_id,
          title: thread.title,
          tags: thread.tags
        })

      for m <- messages do
        Repo.insert!(%Message{
          thread_id: fork.id,
          role: m.role,
          content: m.content,
          metadata: m.metadata,
          usage: m.usage,
          tool_calls: m.tool_calls,
          tool_call_id: m.tool_call_id,
          inserted_at: m.inserted_at
        })
      end

      {:ok, fork}
    end)
  end

  @doc """
  Deletes a thread's messages after the one with id `after_id`, and the runs that answered the
  deleted user messages. Fails while the thread has an active run, and with
  `{:error, :not_found}` if `after_id` isn't one of the thread's messages.
  """
  def truncate_thread(%Thread{} = thread, after_id) do
    with %Message{id: after_id} <- get_thread_message(thread, after_id) do
      if Repo.exists?(
           from r in Run, where: r.thread_id == ^thread.id and r.status in ^Run.active_statuses()
         ) do
        {:error, :run_active}
      else
        {count, _} =
          Repo.delete_all(
            from m in Message, where: m.thread_id == ^thread.id and m.id > ^after_id
          )

        {:ok, count}
      end
    end
  end

  defp get_thread_message(%Thread{id: thread_id}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Message{} = message <- Repo.get_by(Message, id: id, thread_id: thread_id) do
      message
    else
      _ -> {:error, :not_found}
    end
  end

  # Thread hooks use the agent's current settings (there is no run to freeze them in).
  defp notify_extensions(_hook, _thread, nil), do: :ok

  defp notify_extensions(hook, thread, agent) do
    Extensions.notify(
      Extensions.enabled(agent),
      hook,
      [thread],
      Context.for_thread(thread, agent)
    )
  end

  ## Messages

  @doc """
  A page of a thread's messages, oldest first. Returns the `limit` (default 50) most recent
  messages, or the ones before the message with id `before`, and whether there are older ones.
  """
  def list_messages(%Thread{id: thread_id}, opts \\ []) do
    limit = page_size(opts[:limit])

    query =
      from m in Message,
        where: m.thread_id == ^thread_id,
        order_by: [desc: m.id],
        limit: ^(limit + 1)

    query =
      case Ecto.UUID.cast(opts[:before]) do
        {:ok, before} -> where(query, [m], m.id < ^before)
        :error -> query
      end

    messages = Repo.all(query)
    {messages |> Enum.take(limit) |> Enum.reverse(), length(messages) > limit}
  end

  @doc """
  What a run continues from, oldest first: the thread's messages up to the run's user message,
  and the messages the run has saved since.
  """
  def list_run_history(%Meridian.Runs.Run{} = run) do
    Repo.all(
      from m in Message,
        where:
          m.thread_id == ^run.thread_id and (m.id <= ^run.user_message_id or m.run_id == ^run.id),
        order_by: m.id
    )
  end

  @doc "All messages of a thread, oldest first."
  def list_all_messages(%Thread{id: thread_id}) do
    Repo.all(from m in Message, where: m.thread_id == ^thread_id, order_by: m.id)
  end

  @doc """
  Adds a user message to a thread and starts a run to reply to it. Returns right away with
  `{:ok, message, run}`; the run executes in the background.

  The run uses the thread's agent (or the key's default agent if the thread's was
  deleted), frozen into the run. Fails with `{:error, :run_active}` if the thread already has
  an active run, and `{:error, :agent_not_found}` if the key may not use the agent.
  """
  def send_message(%Thread{} = thread, %Policy{} = policy, attrs) do
    with {:ok, agent} <- run_agent(thread, policy),
         {:ok, {message, run}} <- insert_message_and_run(thread, agent, attrs) do
      Meridian.Runs.broadcast_run(run)
      {:ok, message, run}
    end
  end

  @doc """
  Starts a run to reply to the thread's last message, which must be a user message without a
  reply (e.g. after `truncate_thread/2` or `fork_thread/2`). Fails with
  `{:error, :nothing_to_reply}` otherwise, and like `send_message/3` on an active run or an
  agent the key may not use.
  """
  def reply(%Thread{} = thread, %Policy{} = policy) do
    with {:ok, agent} <- run_agent(thread, policy),
         {:ok, message} <- awaiting_reply(thread),
         {:ok, run} <- Repo.transact(fn -> start_run(thread, agent, message) end) do
      Meridian.Runs.broadcast_run(run)
      {:ok, run}
    end
  end

  defp awaiting_reply(%Thread{id: thread_id}) do
    case Repo.one(
           from m in Message, where: m.thread_id == ^thread_id, order_by: [desc: m.id], limit: 1
         ) do
      %Message{role: "user"} = message -> {:ok, message}
      _ -> {:error, :nothing_to_reply}
    end
  end

  defp run_agent(thread, policy) do
    slug = if thread.agent, do: thread.agent.slug
    Agents.resolve_agent(%User{id: thread.user_id}, policy, slug)
  end

  defp insert_message_and_run(thread, agent, attrs) do
    Repo.transact(fn ->
      with {:ok, message} <-
             Repo.insert(Message.user_changeset(%Message{thread_id: thread.id}, attrs)),
           {:ok, run} <- start_run(thread, agent, message) do
        {:ok, {message, run}}
      end
    end)
  end

  # Inserts a run replying to `message` and its job, and moves the thread up the list. Call in
  # a transaction.
  defp start_run(thread, agent, message) do
    with {:ok, run} <- insert_run(thread, agent, message),
         {:ok, _job} <- Oban.insert(Worker.new(%{run_id: run.id})) do
      Repo.update_all(from(t in Thread, where: t.id == ^thread.id),
        set: [updated_at: DateTime.utc_now()]
      )

      {:ok, run}
    end
  end

  # The only way inserting a valid run fails is the one-active-run-per-thread index.
  defp insert_run(thread, agent, message) do
    %Run{}
    |> Run.create_changeset(%{
      thread_id: thread.id,
      user_message_id: message.id,
      agent_snapshot: Agent.snapshot(agent),
      model: agent.model
    })
    |> Repo.insert()
    |> case do
      {:ok, run} -> {:ok, run}
      {:error, _changeset} -> {:error, :run_active}
    end
  end

  defp agent_slug(agent) when is_binary(agent) do
    case Agent.slug_from_model_id(agent) do
      {:ok, slug} -> slug
      :error -> agent
    end
  end

  defp agent_slug(_agent), do: nil

  defp page_size(nil), do: @default_page_size
  defp page_size(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_page_size)

  defp page_size(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, ""} -> page_size(limit)
      _ -> @default_page_size
    end
  end
end
