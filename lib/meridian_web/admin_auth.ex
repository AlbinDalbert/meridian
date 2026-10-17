defmodule MeridianWeb.AdminAuth do
  @moduledoc """
  Authentication for the operator console under `/admin`.

  Admin access belongs to the operator of the deployment, not to a Meridian user, so it has its
  own ways in. Either or both can be enabled; with neither, `/admin` is disabled entirely.

    * **Sign-in with the OIDC provider** (`OIDC_ISSUER`, `OIDC_CLIENT_ID`, `ADMIN_EMAILS`): the operator
      logs in at the provider and gets in if their verified email is in `ADMIN_EMAILS`.
      The session stores the email; removing it from `ADMIN_EMAILS` logs them out.
    * **The `ADMIN_TOKEN` secret**, pasted into the login form. The session stores a hash of the
      token, so rotating the token logs everyone out.

  Both kinds of session live in a signed cookie scoped to `/admin` and expire after 12 hours.
  """
  use MeridianWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  @max_age_seconds 12 * 60 * 60
  @token_hash_key "admin_token_hash"
  @email_key "admin_email"
  @signed_in_at_key "admin_signed_in_at"

  @doc """
  Options for the admin session cookie. Used by the admin router pipeline and the LiveView
  socket, so both see the same session.
  """
  def session_options do
    [
      store: :cookie,
      key: "_meridian_admin",
      signing_salt: "f1Y3l6Qh",
      path: "/admin",
      max_age: @max_age_seconds,
      same_site: "Strict",
      http_only: true
    ]
  end

  @doc "Whether the admin console is enabled (`ADMIN_TOKEN` or admin OIDC sign-in is set up)."
  def enabled?, do: token_login?() or oidc_login?()

  @doc "Whether operators can log in with `ADMIN_TOKEN`."
  def token_login?, do: admin_token() != nil

  @doc "Whether operators can sign in with the OIDC provider (it is set up and `ADMIN_EMAILS` too)."
  def oidc_login?, do: Meridian.OIDC.sign_in_enabled?() and admin_emails() != []

  @doc "Whether `email` is one of `ADMIN_EMAILS` (case-insensitive)."
  def admin_email?(email) when is_binary(email), do: normalize_email(email) in admin_emails()

  def admin_email?(_email), do: false

  @doc "Constant-time check of a submitted token against `ADMIN_TOKEN`."
  def valid_token?(token) when is_binary(token) do
    case admin_token() do
      nil -> false
      admin_token -> Plug.Crypto.secure_compare(hash(token), hash(admin_token))
    end
  end

  def valid_token?(_token), do: false

  @doc "Starts an admin session on `conn` after a valid `ADMIN_TOKEN`."
  def log_in(conn) do
    conn
    |> new_session()
    |> put_session(@token_hash_key, Base.encode64(hash(admin_token())))
  end

  @doc "Starts an admin session on `conn` for an operator signed in with the OIDC provider."
  def log_in_oidc(conn, email) do
    conn
    |> new_session()
    |> put_session(@email_key, normalize_email(email))
  end

  defp new_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(@signed_in_at_key, System.system_time(:second))
  end

  @doc "Ends the admin session on `conn`."
  def log_out(conn), do: configure_session(conn, drop: true)

  @doc "Whether a session map holds a valid, unexpired admin session."
  def admin_session?(%{@token_hash_key => token_hash, @signed_in_at_key => signed_in_at})
      when is_binary(token_hash) and is_integer(signed_in_at) do
    with admin_token when is_binary(admin_token) <- admin_token(),
         true <- System.system_time(:second) - signed_in_at < @max_age_seconds do
      Plug.Crypto.secure_compare(token_hash, Base.encode64(hash(admin_token)))
    else
      _ -> false
    end
  end

  def admin_session?(%{@email_key => email, @signed_in_at_key => signed_in_at})
      when is_binary(email) and is_integer(signed_in_at) do
    oidc_login?() and admin_email?(email) and
      System.system_time(:second) - signed_in_at < @max_age_seconds
  end

  def admin_session?(_session), do: false

  ## Plugs

  @doc "Responds 404 to everything under `/admin` when the console is disabled."
  def require_admin_enabled(conn, _opts) do
    if enabled?() do
      conn
    else
      conn |> send_resp(:not_found, "Not Found") |> halt()
    end
  end

  @doc "Redirects to the login page unless the request carries a valid admin session."
  def require_admin(conn, _opts) do
    if admin_session?(get_session(conn)) do
      conn
    else
      conn
      |> log_out()
      |> redirect(to: ~p"/admin/login")
      |> halt()
    end
  end

  ## LiveView

  @doc """
  `on_mount` hook for admin LiveViews. The plug guards the initial HTTP render; this guards the
  WebSocket connection, which doesn't go through the router pipeline.
  """
  def on_mount(:require_admin, _params, session, socket) do
    if admin_session?(session) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/admin/login")}
    end
  end

  defp admin_token, do: Application.get_env(:meridian, :admin_token)

  # Lowercased by config/runtime.exs.
  defp admin_emails, do: Application.get_env(:meridian, :admin_emails, [])

  defp hash(token), do: :crypto.hash(:sha256, token)

  defp normalize_email(email), do: email |> String.trim() |> String.downcase()
end
