defmodule MeridianWeb.AdminAuth do
  @moduledoc """
  Authentication for the operator console under `/admin`.

  Admin access belongs to the operator of the deployment, not to a Meridian user, so it uses its
  own credential: the `ADMIN_TOKEN` secret. If it is unset, `/admin` is disabled entirely.

  Logging in stores a hash of the token and the login time in a signed cookie scoped to
  `/admin`. A session is valid only while it is younger than 12 hours
  and its hash matches the current token, so rotating the token logs everyone out.
  """
  use MeridianWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  @max_age_seconds 12 * 60 * 60
  @token_hash_key "admin_token_hash"
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

  @doc "Whether the admin console is enabled (`ADMIN_TOKEN` is set)."
  def enabled?, do: admin_token() != nil

  @doc "Constant-time check of a submitted token against `ADMIN_TOKEN`."
  def valid_token?(token) when is_binary(token) do
    case admin_token() do
      nil -> false
      admin_token -> Plug.Crypto.secure_compare(hash(token), hash(admin_token))
    end
  end

  def valid_token?(_token), do: false

  @doc "Starts an admin session on `conn`."
  def log_in(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(@token_hash_key, Base.encode64(hash(admin_token())))
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

  defp hash(token), do: :crypto.hash(:sha256, token)
end
