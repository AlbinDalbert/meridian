defmodule MeridianWeb.UserAuth do
  @moduledoc """
  Sign-in sessions for users of browser apps, e.g. xebec (see `MeridianWeb.Api.AuthController`).

  A browser-only app can't complete the provider's login itself: trading the authorization code
  for tokens is a request to the provider's token endpoint, which browsers block unless the
  provider allows the app's origin (CORS), and WorkOS doesn't for OAuth applications. So
  Meridian runs the login, as it does for `/admin`, and keeps the session in a cookie that `/api`
  accepts in place of a bearer token (`MeridianWeb.Plugs.ApiKeyAuth` with `session: true`).

  The app must reach Meridian on its own origin (a reverse proxy routing `/api` to Meridian), so
  the cookie is first-party. Cross-origin use stays cookie-free: `MeridianWeb.Plugs.CORS` never
  allows credentials.

  The cookie is signed, scoped to `/api`, and holds the user id and their linked identity, so
  deleting the user or unlinking the identity ends the session. It is `SameSite=Lax` because
  the browser lands on the app right after a redirect from the provider's site. Requests that
  change something must also send an `X-Requested-With` header: a page on another origin can
  only add one after a CORS preflight, which never allows credentials, so a sibling subdomain
  (same site, so the cookie is sent) can't forge them.
  """
  import Plug.Conn

  alias Meridian.Accounts
  alias Meridian.Accounts.User
  alias Meridian.OIDC

  @cookie "_meridian_user"
  @max_age 14 * 24 * 60 * 60

  @doc "Whether users can sign in with the OIDC provider (`USER_OIDC_CLIENT_ID` is set)."
  def enabled?, do: user_oidc() != nil and OIDC.issuer() != nil

  @doc "The user sign-in client settings: `:client_id` and `:client_secret` (optional)."
  def user_oidc, do: Application.get_env(:meridian, :user_oidc)

  @doc "Starts a sign-in session for `user`, who must be linked to a provider identity."
  def log_in(conn, %User{oidc_issuer: issuer, oidc_subject: subject} = user)
      when is_binary(issuer) and is_binary(subject) do
    put_resp_cookie(conn, @cookie, {user.id, issuer, subject}, cookie_options(conn, sign: true))
  end

  @doc "Ends the sign-in session, if any."
  def log_out(conn), do: delete_resp_cookie(conn, @cookie, cookie_options(conn))

  @doc "The user of the request's sign-in session, or `nil`."
  def session_user(conn) do
    conn = fetch_cookies(conn, signed: [@cookie])

    with true <- enabled?(),
         {id, issuer, subject} <- conn.cookies[@cookie] do
      Accounts.get_linked_user(id, issuer, subject)
    else
      _ -> nil
    end
  end

  @doc "Whether a cookie-authenticated request may go ahead (see the moduledoc)."
  def csrf_safe?(conn) do
    conn.method in ["GET", "HEAD", "OPTIONS"] or get_req_header(conn, "x-requested-with") != []
  end

  @doc """
  The URL the browser used for `path`. Behind a reverse proxy (such as xebec's), that comes
  from `X-Forwarded-Proto` and `X-Forwarded-Host`. Only used for the redirect URI, which the
  provider checks against the ones registered for the client, and the cookies' `Secure` flag.
  """
  def public_url(conn, path), do: "#{scheme(conn)}://#{host(conn)}#{path}"

  @doc "Cookie options shared by the session and sign-in flow cookies."
  def cookie_options(conn, opts \\ []) do
    Keyword.merge(
      [
        max_age: @max_age,
        path: "/api",
        same_site: "Lax",
        http_only: true,
        secure: scheme(conn) == "https"
      ],
      opts
    )
  end

  defp scheme(conn) do
    case forwarded(conn, "x-forwarded-proto") do
      scheme when scheme in ["http", "https"] -> scheme
      _ -> to_string(conn.scheme)
    end
  end

  defp host(conn) do
    forwarded(conn, "x-forwarded-host") || forwarded(conn, "host") ||
      if conn.port in [80, 443], do: conn.host, else: "#{conn.host}:#{conn.port}"
  end

  # The first value, if a proxy chain sent several.
  defp forwarded(conn, header) do
    case get_req_header(conn, header) do
      [value | _] ->
        case value |> String.split(",") |> hd() |> String.trim() do
          "" -> nil
          value -> value
        end

      [] ->
        nil
    end
  end
end
