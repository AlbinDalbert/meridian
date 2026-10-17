defmodule MeridianWeb.Plugs.ApiKeyAuth do
  @moduledoc """
  Authenticates requests with a bearer token in the `Authorization` header: a Meridian API key
  (`mrd_...`), or, when `OIDC_AUDIENCES` is set, an access token from the OIDC provider (see
  `Meridian.Accounts.authenticate_access_token/1`).

  On success, assigns `:current_user`, `:current_policy`, and `:current_api_key` (`nil` for
  provider access tokens, which get the default policy: all of the user's personas).
  Otherwise responds `401` with an OpenAI-style error.

  With `events_token: true` (run event streams only), a `?token=` query param holding the
  run's `MeridianWeb.EventsToken` is accepted instead, for browsers' `EventSource`.
  """
  @behaviour Plug

  import Plug.Conn

  alias Meridian.Accounts
  alias Meridian.Accounts.{ApiKey, User}
  alias Meridian.Accounts.ApiKey.Policy
  alias Meridian.OIDC
  alias Meridian.OIDC.JWT
  alias MeridianWeb.EventsToken
  alias MeridianWeb.V1.OpenAIError

  @impl true
  def init(opts), do: Keyword.validate!(opts, events_token: false)

  @impl true
  def call(conn, opts) do
    case authenticate(conn, opts[:events_token]) do
      {:ok, %ApiKey{} = api_key} ->
        conn
        |> assign(:current_api_key, api_key)
        |> assign(:current_user, api_key.user)
        |> assign(:current_policy, api_key.policy)

      {:ok, %User{} = user} ->
        conn
        |> assign(:current_api_key, nil)
        |> assign(:current_user, user)
        |> assign(:current_policy, %Policy{})

      :missing ->
        OpenAIError.send_error(
          conn,
          401,
          "missing_api_key",
          "You didn't provide an API key. Send it as `Authorization: Bearer <key>`."
        )

      {:error, :unknown_user} ->
        OpenAIError.send_error(
          conn,
          401,
          "unknown_user",
          "This sign-in has no Meridian user. Ask the operator to add a user with your email."
        )

      {:error, :provider_unavailable} ->
        OpenAIError.send_error(
          conn,
          503,
          "auth_unavailable",
          "The sign-in provider can't be reached to check this token. Try again shortly."
        )

      _error ->
        OpenAIError.send_error(conn, 401, "invalid_api_key", "Invalid or revoked API key.")
    end
  end

  defp authenticate(conn, events_token?) do
    case bearer_token(conn) do
      {:ok, token} -> authenticate_bearer(token)
      :missing when events_token? -> authenticate_events_token(conn)
      :missing -> :missing
    end
  end

  defp authenticate_bearer(token) do
    cond do
      ApiKey.token?(token) -> Accounts.authenticate_api_key(token)
      OIDC.client_tokens_enabled?() and JWT.jwt?(token) -> authenticate_access_token(token)
      true -> :error
    end
  end

  defp authenticate_access_token(token) do
    case Accounts.authenticate_access_token(token) do
      {:ok, user} -> {:ok, user}
      {:error, reason} when reason in [:unknown_user, :provider_unavailable] -> {:error, reason}
      {:error, _invalid} -> :error
    end
  end

  defp authenticate_events_token(conn) do
    conn = fetch_query_params(conn)

    with %{"token" => token} when is_binary(token) <- conn.query_params,
         {:ok, credential} <- EventsToken.verify(token, conn.path_params["id"]),
         %{} = api_key_or_user <- get_credential(credential) do
      {:ok, api_key_or_user}
    else
      %{} -> :missing
      _ -> :error
    end
  end

  defp get_credential({:api_key, id}), do: Accounts.get_active_api_key(id)
  defp get_credential({:user, id}), do: Accounts.get_user(id)

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
