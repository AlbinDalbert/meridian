defmodule Meridian.Accounts.ApiKey do
  @moduledoc """
  An API key identifies a user to clients. Only a SHA-256 hash of the token is stored, plus a
  short visible prefix so keys can be told apart. The plaintext token is shown once, at minting.
  """
  use Meridian.Schema

  import Ecto.Changeset

  alias Meridian.Accounts.ApiKey.Policy

  @token_prefix "mrd_"
  @visible_prefix_length 12

  schema "api_keys" do
    field :name, :string
    field :prefix, :string
    field :token_hash, :binary, redact: true
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    # Set only on a freshly minted key; never persisted.
    field :token, :string, virtual: true, redact: true

    embeds_one :policy, Policy, on_replace: :update, defaults_to_struct: true

    belongs_to :user, Meridian.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 200)
    |> cast_embed(:policy)
  end

  @doc """
  Builds a changeset for a new key with a freshly generated token. The plaintext token is
  available in the `:token` virtual field of the inserted struct.
  """
  def mint_changeset(api_key, attrs) do
    token = generate_token()

    api_key
    |> changeset(attrs)
    |> put_change(:token, token)
    |> put_change(:prefix, String.slice(token, 0, @visible_prefix_length))
    |> put_change(:token_hash, hash_token(token))
    |> unique_constraint(:token_hash)
  end

  @doc "Hashes a plaintext token the way it is stored."
  def hash_token(token), do: :crypto.hash(:sha256, token)

  @doc "Whether a string looks like a Meridian API key."
  def token?(token), do: String.starts_with?(token, @token_prefix)

  defp generate_token do
    @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end
end
