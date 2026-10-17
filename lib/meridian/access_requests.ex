defmodule Meridian.AccessRequests do
  @moduledoc """
  Requests to be added to Meridian, left by people on the public request page (`/me/request`)
  for the operator to accept, snooze, or reject.

  This is not signup: nothing happens until the operator accepts, and accepting is creating the
  user (`Meridian.Accounts.create_user/3`), after which the person signs in as usual. Snoozing
  only moves a request out of the way ("I'll look at this later"); rejecting keeps it, so the
  same email asking again doesn't bring it back, until the operator restores it. Each email has
  at most one request: asking again moves it to the top of its list.
  """
  import Ecto.Query

  alias Meridian.Accounts
  alias Meridian.AccessRequests.AccessRequest
  alias Meridian.Repo

  # Requests waiting for the operator (pending or snoozed). Past this, the page stops taking
  # new ones, so a script filling in the public form can only fill up so much.
  @max_open 200

  @doc "A changeset for a new request, for the request form."
  def change_request(attrs \\ %{}), do: AccessRequest.changeset(%AccessRequest{}, attrs)

  @doc """
  Records a request to be added. There is one request per email (case-insensitive): asking
  again moves the existing request to the top of its list (`requested_at`), counts it
  (`times_requested`), and takes the new name if one is given. It keeps its status, so a
  snoozed request stays snoozed and a rejected one stays rejected.

  Returns `{:ok, :requested}` whatever the email, also when it already has a user (and then
  nothing is saved), so the page says the same thing whoever asks and doesn't reveal who has
  access. Returns `{:error, changeset}` for an invalid email or name, and `{:error, :full}` when
  too many requests are already waiting and this would be a new one.
  """
  @spec request_access(map()) :: {:ok, :requested} | {:error, Ecto.Changeset.t() | :full}
  def request_access(attrs) do
    changeset = AccessRequest.changeset(%AccessRequest{}, attrs)

    with {:ok, request} <- Ecto.Changeset.apply_action(changeset, :insert) do
      cond do
        Accounts.get_user_by_email(request.email) ->
          {:ok, :requested}

        not requested?(request.email) and count_open() >= @max_open ->
          {:error, :full}

        true ->
          upsert(changeset)
      end
    end
  end

  # Inserts the request, or bumps the one with the same email. In one statement, so two
  # requests for the same email at once can't make two rows.
  defp upsert(changeset) do
    now = DateTime.utc_now()

    bump =
      from r in AccessRequest,
        update: [
          inc: [times_requested: 1],
          set: [
            requested_at: ^now,
            updated_at: ^now,
            name: fragment("COALESCE(EXCLUDED.name, ?)", r.name)
          ]
        ]

    changeset
    |> Ecto.Changeset.put_change(:requested_at, now)
    |> Repo.insert(on_conflict: bump, conflict_target: {:unsafe_fragment, "(lower(email))"})
    |> case do
      {:ok, _request} -> {:ok, :requested}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp requested?(email) do
    email = String.downcase(email)
    Repo.exists?(from r in AccessRequest, where: fragment("lower(?)", r.email) == ^email)
  end

  defp count_open do
    Repo.aggregate(from(r in AccessRequest, where: r.status in ["pending", "snoozed"]), :count)
  end

  @doc "Requests with `status`, the most recently asked first."
  def list_requests(status) do
    Repo.all(
      from r in AccessRequest,
        where: r.status == ^status,
        order_by: [desc: r.requested_at, desc: r.id]
    )
  end

  def get_request!(id), do: Repo.get!(AccessRequest, id)

  @doc "Moves a request to the snoozed list."
  def snooze(%AccessRequest{} = request), do: set_status(request, "snoozed")

  @doc "Rejects a request. It is kept, so the same email can't ask again."
  def reject(%AccessRequest{} = request), do: set_status(request, "rejected")

  @doc "Puts a snoozed or rejected request back with the pending ones."
  def restore(%AccessRequest{} = request), do: set_status(request, "pending")

  defp set_status(request, status) do
    request |> AccessRequest.status_changeset(status) |> Repo.update()
  end

  @doc """
  Accepts a request: creates the user, with a default agent from `agent_attrs` (at least
  `"model"`), and deletes the request. The user's name is the one they gave, or the start of
  their email. Takes the same options and returns the same errors as
  `Meridian.Accounts.create_user/3`.
  """
  def accept(%AccessRequest{} = request, agent_attrs, opts \\ []) do
    user_attrs = %{"email" => request.email, "name" => request.name || email_name(request.email)}

    Repo.transact(fn ->
      case Accounts.create_user(user_attrs, agent_attrs, opts) do
        {:ok, user} ->
          Repo.delete!(request)
          {:ok, user}

        {:error, kind, changeset} ->
          {:error, {kind, changeset}}
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, {kind, changeset}} -> {:error, kind, changeset}
    end
  end

  defp email_name(email), do: email |> String.split("@") |> hd()
end
