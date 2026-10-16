defmodule MeridianWeb.Plugs.ApiKeyAuth do
  @moduledoc """
  Authenticates requests with a Meridian API key in the `Authorization: Bearer mrd_...` header.

  On success, assigns `:current_api_key` (with its user preloaded) and `:current_user`.
  Otherwise responds `401` with an OpenAI-style error.
  """
  @behaviour Plug

  import Plug.Conn

  alias Meridian.Accounts
  alias MeridianWeb.V1.OpenAIError

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, api_key} <- Accounts.authenticate_api_key(token) do
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
