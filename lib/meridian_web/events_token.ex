defmodule MeridianWeb.EventsToken do
  @moduledoc """
  Tokens for reading one run's event stream without an `Authorization` header.

  Browsers' `EventSource` can't send headers, so run responses include an `events_token` that
  a client puts in the query string: `GET /api/runs/:id/events?token=...`. The token is signed,
  only valid for that run's events, tied to the API key it was issued to (revoking the key
  revokes it), and expires after an hour, which bounds the damage if a URL ends up in a log.
  """
  alias Meridian.Accounts.ApiKey
  alias Meridian.Runs.Run

  @salt "run events"
  @max_age 60 * 60

  def sign(%Run{id: run_id}, %ApiKey{id: api_key_id}) do
    Phoenix.Token.sign(MeridianWeb.Endpoint, @salt, {run_id, api_key_id})
  end

  @doc "Returns the id of the API key the token was issued to, if it is valid for `run_id`."
  def verify(token, run_id) when is_binary(token) do
    case Phoenix.Token.verify(MeridianWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, {^run_id, api_key_id}} -> {:ok, api_key_id}
      _ -> :error
    end
  end
end
