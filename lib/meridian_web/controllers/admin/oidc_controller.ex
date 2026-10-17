defmodule MeridianWeb.Admin.OIDCController do
  @moduledoc """
  Admin sign-in with the OIDC provider: the authorization code flow with PKCE.

  `new/2` sends the browser to the provider with a random `state`, `nonce`, and PKCE challenge,
  which it also stores in a short-lived encrypted cookie. `callback/2` checks the `state`,
  exchanges the code, verifies the ID token (signature, issuer, audience, nonce), and starts an
  admin session if the email is one of `ADMIN_EMAILS`.

  The flow cookie is `SameSite=Lax` because the callback is a navigation from the provider's
  site, and the admin session cookie (`SameSite=Strict`) isn't sent on it. For the same reason
  the callback doesn't redirect into the console: it renders a page that moves on by itself,
  which counts as a same-site navigation, so the new session cookie comes along.
  """
  use MeridianWeb, :controller

  require Logger

  alias Meridian.OIDC
  alias MeridianWeb.AdminAuth

  @flow_cookie "_meridian_admin_oidc"
  @flow_max_age 10 * 60

  def new(conn, _params) do
    with true <- AdminAuth.oidc_login?(),
         flow = %{
           state: OIDC.random_token(),
           nonce: OIDC.random_token(),
           verifier: OIDC.random_token()
         },
         {:ok, url} <-
           OIDC.authorize_url(
             client_id: AdminAuth.admin_oidc()[:client_id],
             redirect_uri: redirect_uri(),
             state: flow.state,
             nonce: flow.nonce,
             code_challenge: OIDC.code_challenge(flow.verifier)
           ) do
      conn
      |> put_resp_cookie(@flow_cookie, flow, flow_cookie_options())
      |> redirect(external: url)
    else
      false -> send_resp(conn, :not_found, "Not Found")
      {:error, _reason} -> fail(conn, "The sign-in provider can't be reached. Try again shortly.")
    end
  end

  def callback(conn, params) do
    conn = fetch_cookies(conn, encrypted: [@flow_cookie])
    flow = conn.cookies[@flow_cookie]
    conn = delete_resp_cookie(conn, @flow_cookie, flow_cookie_options())

    with true <- AdminAuth.oidc_login?() || :not_found,
         %{"code" => code, "state" => state} when is_binary(code) and is_binary(state) <- params,
         %{state: expected_state} when is_binary(expected_state) <- flow,
         true <- Plug.Crypto.secure_compare(state, expected_state) || :invalid_state,
         {:ok, email} <- authenticate(code, flow) do
      if AdminAuth.admin_email?(email) do
        conn
        |> AdminAuth.log_in_oidc(email)
        |> render(:signed_in, page_title: "Signing in")
      else
        Logger.warning("Admin sign-in refused for #{email}: not in ADMIN_EMAILS")
        fail(conn, "#{email} isn't allowed into this admin console.", :forbidden)
      end
    else
      :not_found ->
        send_resp(conn, :not_found, "Not Found")

      %{"error" => error} ->
        fail(conn, "Sign-in was cancelled or failed (#{error}).")

      {:error, :email_unverified} ->
        fail(conn, "Your email isn't verified with the sign-in provider.", :forbidden)

      _ ->
        fail(conn, "Sign-in failed. Try again.")
    end
  end

  # Exchanges the code and returns the verified email.
  defp authenticate(code, flow) do
    config = AdminAuth.admin_oidc()

    with {:ok, claims} <-
           OIDC.complete_sign_in(
             client_id: config[:client_id],
             client_secret: config[:client_secret],
             redirect_uri: redirect_uri(),
             code: code,
             code_verifier: flow.verifier,
             nonce: flow.nonce
           ) do
      cond do
        not is_binary(claims["email"]) -> {:error, :no_email}
        claims["email_verified"] == false -> {:error, :email_unverified}
        true -> {:ok, claims["email"]}
      end
    else
      {:error, reason} = error ->
        Logger.warning("Admin sign-in failed: #{inspect(reason)}")
        error
    end
  end

  defp fail(conn, message, status \\ :unauthorized) do
    conn
    |> put_status(status)
    |> put_flash(:error, message)
    |> put_view(MeridianWeb.Admin.SessionHTML)
    |> render(:new, page_title: "Log in")
  end

  defp redirect_uri, do: url(~p"/admin/auth/callback")

  defp flow_cookie_options do
    [
      encrypt: true,
      max_age: @flow_max_age,
      path: "/admin/auth",
      same_site: "Lax",
      http_only: true
    ]
  end
end
