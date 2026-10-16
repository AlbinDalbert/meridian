defmodule MeridianWeb.Plugs.ApiKeyAuth do
  @moduledoc """
  Authenticates requests with a Meridian API key in the `Authorization: Bearer mrd_...` header.

  On success, assigns `:current_api_key` (with its user preloaded) and `:current_user`.
  Otherwise responds `401` with an OpenAI-style error.

  With `events_token: true` (run event streams only), a `?token=` query param holding the
  run's `MeridianWeb.EventsToken` is accepted instead, for browsers' `EventSource`.
  """
  @behaviour Plug

  import Plug.Conn

  alias Meridian.Accounts
  alias MeridianWeb.EventsToken
  alias MeridianWeb.V1.OpenAIError

  @impl true
  def init(opts), do: Keyword.validate!(opts, events_token: false)

  @impl true
  def call(conn, opts) do
    with {:ok, api_key} <- authenticate(conn, opts[:events_token]) do
      conn
      |> assign(:current_api_key, api_key)
      |> assign(:current_user, api_key.user)
    else
      :missing ->
        OpenAIError.send_error(
          conn,
          401,
          "missing_api_key",
          "You didn't provide an API key. Send it as `Authorization: Bearer <key>`."
        )

      :error ->
        OpenAIError.send_error(conn, 401, "invalid_api_key", "Invalid or revoked API key.")
    end
  end

  defp authenticate(conn, events_token?) do
    case bearer_token(conn) do
      {:ok, token} -> Accounts.authenticate_api_key(token)
      :missing when events_token? -> authenticate_events_token(conn)
      :missing -> :missing
    end
  end

  defp authenticate_events_token(conn) do
    conn = fetch_query_params(conn)

    with %{"token" => token} when is_binary(token) <- conn.query_params,
         {:ok, api_key_id} <- EventsToken.verify(token, conn.path_params["id"]),
         %{} = api_key <- Accounts.get_active_api_key(api_key_id) do
      {:ok, api_key}
    else
      %{} -> :missing
      _ -> :error
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      [header | _] ->
        case String.split(header, " ", parts: 2) do
          [scheme, token] when scheme in ["Bearer", "bearer"] -> {:ok, String.trim(token)}
          _ -> :missing
        end

      [] ->
        :missing
    end
  end
end
