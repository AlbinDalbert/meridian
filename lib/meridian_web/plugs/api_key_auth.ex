defmodule MeridianWeb.Plugs.ApiKeyAuth do
  @moduledoc """
  Authenticates requests with a bearer token in the `Authorization` header: a Meridian API key
  (`mrd_...`), or, when `OIDC_AUDIENCES` is set, an access token from the OIDC provider (see
  `Meridian.Accounts.authenticate_access_token/1`).

  On success, assigns `:current_user`, `:current_policy`, and `:current_api_key` (`nil` for
  provider access tokens, which get the default policy: all of the user's agents).
  Otherwise responds `401` with an OpenAI-style error.

  Without a bearer token:

    * With `session: true` (`/api`), a sign-in session cookie (see `MeridianWeb.UserAuth`) is
      accepted, like a provider access token. Requests that change something must also send
      `X-Requested-With`, or get a `403`.
    * With `events_token: true` (run event streams only), a `?token=` query param holding the
      run's `MeridianWeb.EventsToken` is accepted, for browsers' `EventSource`.
  """
  @behaviour Plug

  import Plug.Conn

  alias Meridian.Accounts
  alias Meridian.Accounts.{ApiKey, User}
  alias Meridian.Accounts.ApiKey.Policy
  alias Meridian.OIDC
  alias Meridian.OIDC.JWT
  alias MeridianWeb.{EventsToken, UserAuth}
  alias MeridianWeb.V1.OpenAIError

  @impl true
  def init(opts), do: Keyword.validate!(opts, events_token: false, session: false)

  @impl true
  def call(conn, opts) do
    case authenticate(conn, opts) do
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

      {:error, :csrf} ->
        OpenAIError.send_error(
          conn,
          403,
          "missing_requested_with",
          "Requests signed in with a session cookie must send an `X-Requested-With` header."
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

  defp authenticate(conn, opts) do
    with :missing <- bearer_token(conn),
         :missing <- if(opts[:session], do: authenticate_session(conn), else: :missing),
         :missing <- if(opts[:events_token], do: authenticate_events_token(conn), else: :missing) do
      :missing
    else
      {:ok, token} when is_binary(token) -> authenticate_bearer(token)
      result -> result
    end
  end

  defp authenticate_session(conn) do
    case UserAuth.session_user(conn) do
      nil -> :missing
      user -> if UserAuth.csrf_safe?(conn), do: {:ok, user}, else: {:error, :csrf}
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
