defmodule MeridianWeb.Me.SessionController do
  @moduledoc """
  Signing in to `/me` (see `MeridianWeb.MeAuth`): the authorization code flow with PKCE, like
  admin sign-in.

  `oidc/2` sends the browser to the provider with a random `state`, `nonce`, and PKCE challenge,
  which it also stores in a short-lived encrypted cookie. `callback/2` checks the `state`,
  exchanges the code, verifies the ID token, finds the person's user (linking it by email on a
  first sign-in), and starts the session. People without a user are refused.
  """
  use MeridianWeb, :controller

  require Logger

  alias Meridian.{Accounts, OIDC}
  alias MeridianWeb.MeAuth

  @flow_cookie "_meridian_me_oidc"
  @flow_max_age 10 * 60

  def new(conn, _params) do
    if MeAuth.session_user(get_session(conn)) do
      redirect(conn, to: ~p"/me")
    else
      render(conn, :new, page_title: "Sign in")
    end
  end

  def oidc(conn, _params) do
    flow = %{
      state: OIDC.random_token(),
      nonce: OIDC.random_token(),
      verifier: OIDC.random_token()
    }

    case OIDC.authorize_url(
           client_id: OIDC.client()[:client_id],
           redirect_uri: redirect_uri(),
           state: flow.state,
           nonce: flow.nonce,
           code_challenge: OIDC.code_challenge(flow.verifier)
         ) do
      {:ok, url} ->
        conn
        |> put_resp_cookie(@flow_cookie, flow, flow_cookie_options())
        |> redirect(external: url)

      {:error, _reason} ->
        fail(conn, "The sign-in provider can't be reached. Try again shortly.")
    end
  end

  def callback(conn, params) do
    conn = fetch_cookies(conn, encrypted: [@flow_cookie])
    flow = conn.cookies[@flow_cookie]
    conn = delete_resp_cookie(conn, @flow_cookie, flow_cookie_options())

    with %{"code" => code, "state" => state} when is_binary(code) and is_binary(state) <- params,
         %{state: expected_state} when is_binary(expected_state) <- flow,
         true <- Plug.Crypto.secure_compare(state, expected_state) || :invalid_state,
         {:ok, %{"iss" => issuer, "sub" => subject} = claims} <- complete_sign_in(code, flow),
         {:ok, user} <- user_for(issuer, subject, claims) do
      conn
      |> MeAuth.log_in(user)
      |> redirect(to: ~p"/me")
    else
      %{"error" => "access_denied"} ->
        fail(conn, "Sign-in was cancelled.")

      {:error, {:unknown_user, email}} ->
        fail(
          conn,
          "#{email || "Your account"} doesn't have a Meridian user. " <>
            "Ask whoever runs this Meridian to add you.",
          :forbidden
        )

      {:error, :provider_unavailable} ->
        fail(conn, "The sign-in provider can't be reached. Try again shortly.")

      other ->
        Logger.warning("Sign-in to /me failed: #{inspect(other)}")
        fail(conn, "Sign-in failed. Try again.")
    end
  end

  def delete(conn, _params) do
    conn
    |> MeAuth.log_out()
    |> redirect(to: ~p"/me/login")
  end

  defp complete_sign_in(code, flow) do
    config = OIDC.client()

    OIDC.complete_sign_in(
      client_id: config[:client_id],
      client_secret: config[:client_secret],
      redirect_uri: redirect_uri(),
      code: code,
      code_verifier: flow.verifier,
      nonce: flow.nonce
    )
  end

  defp user_for(issuer, subject, claims) do
    case Accounts.user_for_identity(issuer, subject, fn -> {:ok, claims} end) do
      {:error, :unknown_user} -> {:error, {:unknown_user, claims["email"]}}
      result -> result
    end
  end

  defp fail(conn, message, status \\ :unauthorized) do
    conn
    |> put_status(status)
    |> put_flash(:error, message)
    |> render(:new, page_title: "Sign in")
  end

  defp redirect_uri, do: url(~p"/me/auth/callback")

  defp flow_cookie_options do
    [
      encrypt: true,
      max_age: @flow_max_age,
      path: "/me/auth",
      same_site: "Lax",
      http_only: true
    ]
  end
end
