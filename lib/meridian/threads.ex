defmodule Meridian.Threads do
  @moduledoc """
  Threads and their messages: the server-owned conversations of the native API.

  Sending a message creates a queued run (`Meridian.Runs.Run`) that generates the reply in the
  background, independently of the client that sent it.
  """
  import Ecto.Query

  alias Meridian.Accounts.ApiKey.Policy
  alias Meridian.Accounts.User
  alias Meridian.{Personas, Repo}
  alias Meridian.Personas.Persona
  alias Meridian.Runs.{Run, Worker}
  alias Meridian.Threads.{Message, Thread}

  @default_page_size 50
  @max_page_size 200

  ## Threads

  @doc "A user's threads, most recently active first."
  def list_threads(%User{id: user_id}, opts \\ []) do
    Repo.all(
      from t in Thread,
        where: t.user_id == ^user_id,
        order_by: [desc: t.updated_at],
        limit: ^page_size(opts[:limit]),
        preload: :persona
    )
  end

  @doc "Gets one of `user`'s threads (persona preloaded), or nil."
  def get_user_thread(%User{id: user_id}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.one(from t in Thread, where: t.id == ^id and t.user_id == ^user_id, preload: :persona)
    else
      :error -> nil
    end
  end

  def get_thread!(id), do: Thread |> Repo.get!(id) |> Repo.preload([:persona, :user])

  @doc """
  Creates a thread for `user`. `attrs["persona"]` is a persona model id (`meridian/<slug>`) or
  slug; without one the key's default persona is used (see
  `Meridian.Personas.resolve_persona/3`).
  """
  def create_thread(%User{} = user, %Policy{} = policy, attrs) do
    slug = persona_slug(attrs["persona"])

    with {:ok, persona} <- Personas.resolve_persona(user, policy, slug) do
      %Thread{user_id: user.id, persona_id: persona.id, persona: persona}
      |> Thread.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc "Updates a thread's title and, if `attrs[\"persona\"]` is given, its persona."
  def update_thread(%Thread{} = thread, %Policy{} = policy, attrs) do
    persona =
      case Map.fetch(attrs, "persona") do
        {:ok, persona} when is_binary(persona) ->
          Personas.resolve_persona(%User{id: thread.user_id}, policy, persona_slug(persona))

        _ ->
          {:ok, thread.persona}
      end

    with {:ok, persona} <- persona,
         {:ok, thread} <-
           thread
           |> Thread.changeset(attrs)
           |> Ecto.Changeset.put_change(:persona_id, persona && persona.id)
           |> Repo.update() do
      {:ok, %{thread | persona: persona}}
    end
  end

  @doc "Deletes a thread with its messages and runs. Fails while the thread has an active run."
  def delete_thread(%Thread{} = thread) do
    if Repo.exists?(
         from r in Run, where: r.thread_id == ^thread.id and r.status in ^Run.active_statuses()
       ),
       do: {:error, :run_active},
       else: Repo.delete(thread)
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

  @doc "All messages of a thread up to and including `last_message_id`, oldest first."
  def list_messages_until(thread_id, last_message_id) do
    Repo.all(
      from m in Message,
        where: m.thread_id == ^thread_id and m.id <= ^last_message_id,
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

  The run uses the thread's persona (or the key's default persona if the thread's was
  deleted), frozen into the run. Fails with `{:error, :run_active}` if the thread already has
  an active run, and `{:error, :persona_not_found}` if the key may not use the persona.
  """
  def send_message(%Thread{} = thread, %Policy{} = policy, attrs) do
    slug = if thread.persona, do: thread.persona.slug

    with {:ok, persona} <- Personas.resolve_persona(%User{id: thread.user_id}, policy, slug),
         {:ok, {message, run}} <- insert_message_and_run(thread, persona, attrs) do
      Meridian.Runs.broadcast_run(run)
      {:ok, message, run}
    end
  end

  defp insert_message_and_run(thread, persona, attrs) do
    Repo.transact(fn ->
      with {:ok, message} <-
             Repo.insert(Message.user_changeset(%Message{thread_id: thread.id}, attrs)),
           {:ok, run} <- insert_run(thread, persona, message),
           {:ok, _job} <- Oban.insert(Worker.new(%{run_id: run.id})) do
        Repo.update_all(from(t in Thread, where: t.id == ^thread.id),
          set: [updated_at: DateTime.utc_now()]
        )

        {:ok, {message, run}}
      end
    end)
  end

  # The only way inserting a valid run fails is the one-active-run-per-thread index.
  defp insert_run(thread, persona, message) do
    %Run{}
    |> Run.create_changeset(%{
      thread_id: thread.id,
      user_message_id: message.id,
      persona_snapshot: Persona.snapshot(persona),
      model: persona.model
    })
    |> Repo.insert()
    |> case do
      {:ok, run} -> {:ok, run}
      {:error, _changeset} -> {:error, :run_active}
    end
  end

  defp persona_slug(persona) when is_binary(persona) do
    case Persona.slug_from_model_id(persona) do
      {:ok, slug} -> slug
      :error -> persona
    end
  end

  defp persona_slug(_persona), do: nil

  defp page_size(nil), do: @default_page_size
  defp page_size(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_page_size)

  defp page_size(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, ""} -> page_size(limit)
      _ -> @default_page_size
    end
  end
end
