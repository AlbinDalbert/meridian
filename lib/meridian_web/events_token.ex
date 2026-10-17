defmodule MeridianWeb.EventsToken do
  @moduledoc """
  Tokens for reading one run's event stream without an `Authorization` header.

  Browsers' `EventSource` can't send headers, so run responses include an `events_token` that
  a client puts in the query string: `GET /api/runs/:id/events?token=...`. The token is signed,
  only valid for that run's events, tied to the credential it was issued to (revoking the API
  key, or deleting the user for clients signed in through the OIDC provider, revokes it), and
  expires after an hour, which bounds the damage if a URL ends up in a log.
  """
  alias Meridian.Accounts.{ApiKey, User}
  alias Meridian.Runs.Run

  @salt "run events"
  @max_age 60 * 60

  @doc "Signs a token for `run`'s events, for the API key or user (OIDC sign-in) asking."
  def sign(%Run{id: run_id}, %ApiKey{id: api_key_id}) do
    Phoenix.Token.sign(MeridianWeb.Endpoint, @salt, {run_id, {:api_key, api_key_id}})
  end

  def sign(%Run{id: run_id}, %User{id: user_id}) do
    Phoenix.Token.sign(MeridianWeb.Endpoint, @salt, {run_id, {:user, user_id}})
  end

  @doc """
  Returns the credential the token was issued to (`{:api_key, id}` or `{:user, id}`), if it is
  valid for `run_id`.
  """
  def verify(token, run_id) when is_binary(token) do
    case Phoenix.Token.verify(MeridianWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, {^run_id, {kind, id}}} when kind in [:api_key, :user] -> {:ok, {kind, id}}
      # Issued before tokens could belong to users.
      {:ok, {^run_id, api_key_id}} when is_binary(api_key_id) -> {:ok, {:api_key, api_key_id}}
      _ -> :error
    end
  end
end
