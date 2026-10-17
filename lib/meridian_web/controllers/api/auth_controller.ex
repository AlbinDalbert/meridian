defmodule MeridianWeb.Api.AuthController do
  @moduledoc """
  `/api/auth`: signing users of browser apps in with the OIDC provider (see
  `MeridianWeb.UserAuth`).

    * `GET /api/auth/session` says whether sign-in is available and who is signed in, and
      where people manage their own things (`account_url`, Meridian's `/me` at its public URL),
      for apps to link to.
    * `GET /api/auth/login?return_to=/path` sends the browser to the provider. The provider
      sends it back to `GET /api/auth/callback`, which starts the session and redirects to
      `return_to` (a path on the app's origin). With `prompt=login`, the provider asks the
      person to sign in again rather than reusing its own session (for switching accounts
      after logging out). On failure, it adds
      `?sign_in_error=<code>`: `unknown_user`, `cancelled`, `unavailable`, or `failed`.
    * `POST /api/auth/logout` ends the session.

  Like `/admin` sign-in, this is the authorization code flow with PKCE; `state`, `nonce`, the
  code verifier, and where to return to are kept in a short-lived encrypted cookie.
  """
  use MeridianWeb, :controller

  require Logger

  alias Meridian.Accounts
  alias Meridian.OIDC
  alias MeridianWeb.UserAuth

  @flow_cookie "_meridian_user_oidc"
  @flow_max_age 10 * 60

  def show(conn, _params) do
    user = UserAuth.session_user(conn)

    json(conn, %{
      data: %{
        sign_in: UserAuth.enabled?(),
        account_url: MeridianWeb.Endpoint.url() <> "/me",
        user: user && %{id: user.id, name: user.name, email: user.email}
      }
    })
  end

  def login(conn, params) do
    return_to = return_to(params)

    with true <- UserAuth.enabled?(),
         config = OIDC.client(),
         flow = %{
           state: OIDC.random_token(),
           nonce: OIDC.random_token(),
           verifier: OIDC.random_token(),
           redirect_uri: UserAuth.public_url(conn, ~p"/api/auth/callback"),
           return_to: return_to
         },
         {:ok, url} <-
           OIDC.authorize_url(
             client_id: config[:client_id],
             redirect_uri: flow.redirect_uri,
             state: flow.state,
             nonce: flow.nonce,
             code_challenge: OIDC.code_challenge(flow.verifier),
             fresh: params["prompt"] == "login"
           ) do
      conn
      |> put_resp_cookie(@flow_cookie, flow, flow_cookie_options(conn))
      |> redirect(external: url)
    else
      false -> send_resp(conn, :not_found, "Not Found")
      {:error, _reason} -> back(conn, return_to, "unavailable")
    end
  end

  def callback(conn, params) do
    conn = fetch_cookies(conn, encrypted: [@flow_cookie])
    flow = conn.cookies[@flow_cookie]
    conn = delete_resp_cookie(conn, @flow_cookie, flow_cookie_options(conn))
    return_to = if is_map(flow), do: flow.return_to, else: "/"

    with true <- UserAuth.enabled?() || :not_found,
         %{"code" => code, "state" => state} when is_binary(code) and is_binary(state) <- params,
         %{state: expected_state} when is_binary(expected_state) <- flow,
         true <- Plug.Crypto.secure_compare(state, expected_state) || :invalid_state,
         {:ok, %{"iss" => issuer, "sub" => subject} = claims} <- complete_sign_in(code, flow),
         {:ok, user} <- Accounts.user_for_identity(issuer, subject, fn -> {:ok, claims} end) do
      conn
      |> UserAuth.log_in(user)
      |> redirect(to: return_to)
    else
      :not_found ->
        send_resp(conn, :not_found, "Not Found")

      %{"error" => "access_denied"} ->
        back(conn, return_to, "cancelled")

      {:error, :unknown_user} ->
        back(conn, return_to, "unknown_user")

      {:error, :provider_unavailable} ->
        back(conn, return_to, "unavailable")

      other ->
        Logger.warning("User sign-in failed: #{inspect(other)}")
        back(conn, return_to, "failed")
    end
  end

  def logout(conn, _params) do
    conn
    |> UserAuth.log_out()
    |> send_resp(:no_content, "")
  end

  defp complete_sign_in(code, flow) do
    config = OIDC.client()

    OIDC.complete_sign_in(
      client_id: config[:client_id],
      client_secret: config[:client_secret],
      redirect_uri: flow.redirect_uri,
      code: code,
      code_verifier: flow.verifier,
      nonce: flow.nonce
    )
  end

  # Only paths on the app's own origin, so this can't be used to send people elsewhere.
  defp return_to(%{"return_to" => path}) when is_binary(path) do
    if String.match?(path, ~r{\A/(?![/\\])[^\s\\]*\z}), do: path, else: "/"
  end

  defp return_to(_params), do: "/"

  defp back(conn, return_to, error) do
    uri = URI.parse(return_to)
    query = URI.decode_query(uri.query || "") |> Map.put("sign_in_error", error)
    redirect(conn, to: URI.to_string(%{uri | query: URI.encode_query(query)}))
  end

  defp flow_cookie_options(conn) do
    UserAuth.cookie_options(conn,
      encrypt: true,
      max_age: @flow_max_age,
      path: "/api/auth"
    )
  end
end
