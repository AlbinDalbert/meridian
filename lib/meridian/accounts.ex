defmodule Meridian.Accounts do
  @moduledoc """
  Users and their API keys.
  """
  import Ecto.Query

  alias Ecto.Multi
  alias Meridian.Accounts.{ApiKey, User}
  alias Meridian.Personas
  alias Meridian.Repo

  # last_used_at is only written when it is older than this, to avoid a write per request.
  @last_used_resolution_seconds 60

  ## Users

  def list_users do
    Repo.all(from u in User, order_by: [asc: u.inserted_at])
  end

  def get_user!(id), do: Repo.get!(User, id)

  def change_user(%User{} = user, attrs \\ %{}), do: User.changeset(user, attrs)

  @doc """
  Creates a user together with their default persona.

  `persona_attrs` are the default persona's attributes (at least `"model"`); slug and name
  default to `"default"` / `"Default"`. See `Meridian.Personas.create_persona/3` for `opts`.
  Returns `{:error, :user, changeset}` or `{:error, :persona, changeset}` on failure.
  """
  def create_user(user_attrs, persona_attrs, opts \\ []) do
    user_changeset = User.changeset(%User{}, user_attrs)

    persona_attrs =
      Map.merge(%{"slug" => "default", "name" => "Default"}, stringify_keys(persona_attrs))

    persona_changeset =
      Personas.Persona.changeset(%Personas.Persona{is_default: true}, persona_attrs)
      |> Personas.validate_model(opts)

    cond do
      not user_changeset.valid? ->
        {:error, :user, %{user_changeset | action: :insert}}

      not persona_changeset.valid? ->
        {:error, :persona, %{persona_changeset | action: :insert}}

      true ->
        Multi.new()
        |> Multi.insert(:user, user_changeset)
        |> Multi.insert(:persona, fn %{user: user} ->
          Ecto.Changeset.put_change(persona_changeset, :user_id, user.id)
        end)
        |> Repo.transact()
        |> case do
          {:ok, %{user: user}} -> {:ok, user}
          {:error, step, changeset, _changes} -> {:error, step, changeset}
        end
    end
  end

  def update_user(%User{} = user, attrs) do
    user |> User.changeset(attrs) |> Repo.update()
  end

  @doc "Deletes a user along with their API keys and personas."
  def delete_user(%User{} = user), do: Repo.delete(user)

  ## API keys

  def list_api_keys(%User{id: user_id}) do
    Repo.all(
      from k in ApiKey,
        where: k.user_id == ^user_id,
        order_by: [asc: not is_nil(k.revoked_at), desc: k.inserted_at]
    )
  end

  def get_api_key!(id), do: Repo.get!(ApiKey, id)

  def change_api_key(%ApiKey{} = api_key, attrs \\ %{}), do: ApiKey.changeset(api_key, attrs)

  @doc """
  Mints a new API key for `user`. The plaintext token is in the returned key's `:token` field
  and is not retrievable afterwards.
  """
  def mint_api_key(%User{} = user, attrs) do
    %ApiKey{user_id: user.id}
    |> ApiKey.mint_changeset(attrs)
    |> Repo.insert()
  end

  def update_api_key(%ApiKey{} = api_key, attrs) do
    api_key |> ApiKey.changeset(attrs) |> Repo.update()
  end

  def revoke_api_key(%ApiKey{revoked_at: nil} = api_key) do
    api_key
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
    |> Repo.update()
  end

  def revoke_api_key(%ApiKey{} = api_key), do: {:ok, api_key}

  @doc """
  Looks up an active (not revoked) API key by its plaintext token, with its user preloaded, and
  records that it was used.
  """
  def authenticate_api_key(token) when is_binary(token) do
    with true <- ApiKey.token?(token),
         %ApiKey{} = api_key <-
           Repo.one(
             from k in ApiKey,
               where: k.token_hash == ^ApiKey.hash_token(token) and is_nil(k.revoked_at),
               preload: :user
           ) do
      {:ok, touch_last_used(api_key)}
    else
      _ -> :error
    end
  end

  @doc "Gets an active (not revoked) API key by id, with its user preloaded."
  def get_active_api_key(id) do
    Repo.one(from k in ApiKey, where: k.id == ^id and is_nil(k.revoked_at), preload: :user)
  end

  defp touch_last_used(%ApiKey{} = api_key) do
    now = DateTime.utc_now()
    stale_before = DateTime.add(now, -@last_used_resolution_seconds)

    Repo.update_all(
      from(k in ApiKey,
        where: k.id == ^api_key.id,
        where: is_nil(k.last_used_at) or k.last_used_at < ^stale_before
      ),
      set: [last_used_at: now]
    )

    api_key
  end

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
