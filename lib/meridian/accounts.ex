defmodule Meridian.Accounts do
  @moduledoc """
  Users and how clients identify them: API keys, or access tokens from the OIDC provider.
  """
  import Ecto.Query

  alias Meridian.Accounts.{ApiKey, User}
  alias Meridian.OIDC
  alias Meridian.Personas
  alias Meridian.Repo

  # last_used_at is only written when it is older than this, to avoid a write per request.
  @last_used_resolution_seconds 60

  ## Users

  def list_users do
    Repo.all(from u in User, order_by: [asc: u.inserted_at])
  end

  def get_user!(id), do: Repo.get!(User, id)

  def get_user(id), do: Repo.get(User, id)

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
        Repo.transact(fn ->
          with {:ok, user} <- Repo.insert(user_changeset),
               {:ok, _persona} <-
                 persona_changeset
                 |> Ecto.Changeset.put_change(:user_id, user.id)
                 |> Repo.insert() do
            {:ok, user}
          end
        end)
        |> case do
          {:ok, user} -> {:ok, user}
          {:error, %Ecto.Changeset{data: %User{}} = changeset} -> {:error, :user, changeset}
          {:error, changeset} -> {:error, :persona, changeset}
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

  ## OIDC identities

  @doc """
  Authenticates an access token a client got from the OIDC provider (see `Meridian.OIDC`), and
  returns its user (see `user_for_identity/3`). The email for a first sign-in comes from the
  provider's userinfo endpoint.
  """
  @spec authenticate_access_token(String.t()) ::
          {:ok, User.t()} | {:error, :unknown_user | :provider_unavailable | atom()}
  def authenticate_access_token(token) when is_binary(token) do
    with {:ok, %{"iss" => issuer, "sub" => subject}} <-
           OIDC.verify_token(token, OIDC.audiences()) do
      user_for_identity(issuer, subject, fn -> OIDC.userinfo(token) end)
    end
  end

  @doc """
  Returns the user whose linked identity is `issuer` and `subject` at the OIDC provider.

  The first time a subject is seen, it is linked to the user with the same email. `profile` is
  called only then, and returns the provider's claims about the person (`"sub"`, `"email"`,
  `"email_verified"`); an email marked unverified isn't used. There is no signup: without a
  matching user, this returns `{:error, :unknown_user}`. A user already linked to another
  identity is never relinked.
  """
  @spec user_for_identity(String.t(), String.t(), (-> {:ok, map()} | {:error, term()})) ::
          {:ok, User.t()} | {:error, :unknown_user | :provider_unavailable}
  def user_for_identity(issuer, subject, profile)
      when is_binary(issuer) and is_binary(subject) do
    case Repo.get_by(User, oidc_issuer: issuer, oidc_subject: subject) do
      %User{} = user -> {:ok, user}
      nil -> link_by_email(issuer, subject, profile)
    end
  end

  @doc """
  Gets user `id` if it is still linked to the identity `issuer` and `subject`. For sign-in
  sessions: deleting the user or unlinking the identity ends them.
  """
  def get_linked_user(id, issuer, subject) do
    Repo.get_by(User, id: id, oidc_issuer: issuer, oidc_subject: subject)
  end

  defp link_by_email(issuer, subject, profile) do
    with {:ok, %{"sub" => ^subject, "email" => email} = info} when is_binary(email) <-
           profile.(),
         true <- info["email_verified"] != false,
         %User{oidc_subject: nil} = user <- get_user_by_email(email) do
      user
      |> Ecto.Changeset.change(oidc_issuer: issuer, oidc_subject: subject)
      |> Ecto.Changeset.unique_constraint([:oidc_issuer, :oidc_subject])
      |> Repo.update()
      |> case do
        {:ok, user} -> {:ok, user}
        # A concurrent request linked it first.
        {:error, _changeset} -> fetch_linked_user(issuer, subject)
      end
    else
      {:error, :provider_unavailable} -> {:error, :provider_unavailable}
      _ -> {:error, :unknown_user}
    end
  end

  defp fetch_linked_user(issuer, subject) do
    case Repo.get_by(User, oidc_issuer: issuer, oidc_subject: subject) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :unknown_user}
    end
  end

  @doc "Gets the user with `email` (case-insensitive), or `nil`."
  def get_user_by_email(email) do
    email = String.downcase(String.trim(email))
    Repo.one(from u in User, where: fragment("lower(?)", u.email) == ^email)
  end

  @doc "Removes a user's linked sign-in identity, so their next sign-in links again by email."
  def unlink_oidc_identity(%User{} = user) do
    user |> Ecto.Changeset.change(oidc_issuer: nil, oidc_subject: nil) |> Repo.update()
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
