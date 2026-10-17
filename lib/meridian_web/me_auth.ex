defmodule MeridianWeb.MeAuth do
  @moduledoc """
  Sign-in sessions for `/me`, where users manage their own personas.

  Anyone with a Meridian user can sign in, through the OIDC provider, linked to their user the
  same way as every other sign-in (`Meridian.Accounts.user_for_identity/3`): there is no signup.
  `/me` is on whenever user sign-in is (`OIDC_CLIENT_ID` is set) and is 404 otherwise.

  The session is separate from the admin console's and from the `/api` sign-in cookie
  (`MeridianWeb.UserAuth`): a signed cookie scoped to `/me`, valid for 14 days, holding the user
  id and their linked identity, so deleting the user or unlinking the identity ends it. Being
  an operator (`ADMIN_EMAILS`) changes nothing here, and a `/me` session never opens `/admin`.

  The cookie is `SameSite=Lax`, so following a link to `/me` from elsewhere keeps you signed
  in; forms and the LiveView socket are protected by CSRF tokens instead.
  """
  use MeridianWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Meridian.Accounts
  alias Meridian.Accounts.User
  alias Meridian.OIDC

  @max_age_seconds 14 * 24 * 60 * 60
  @user_key "me_user"
  @signed_in_at_key "me_signed_in_at"

  @doc """
  Options for the `/me` session cookie. Used by the `/me` router pipeline and its LiveView
  socket, so both see the same session.
  """
  def session_options do
    [
      store: :cookie,
      key: "_meridian_me",
      signing_salt: "Gd3AbQWK",
      path: "/me",
      max_age: @max_age_seconds,
      same_site: "Lax",
      http_only: true
    ]
  end

  @doc "Whether `/me` is available (users can sign in with the OIDC provider)."
  def enabled?, do: OIDC.sign_in_enabled?()

  @doc "Starts a `/me` session for `user`, who must be linked to a provider identity."
  def log_in(conn, %User{oidc_issuer: issuer, oidc_subject: subject} = user)
      when is_binary(issuer) and is_binary(subject) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(@user_key, {user.id, issuer, subject})
    |> put_session(@signed_in_at_key, System.system_time(:second))
  end

  @doc "Ends the `/me` session on `conn`."
  def log_out(conn), do: configure_session(conn, drop: true)

  @doc "The user of a session map, or `nil` if it holds no valid, unexpired `/me` session."
  def session_user(%{@user_key => {id, issuer, subject}, @signed_in_at_key => signed_in_at})
      when is_integer(signed_in_at) do
    if enabled?() and System.system_time(:second) - signed_in_at < @max_age_seconds do
      Accounts.get_linked_user(id, issuer, subject)
    end
  end

  def session_user(_session), do: nil

  ## Plugs

  @doc "Responds 404 to everything under `/me` when user sign-in isn't set up."
  def require_me_enabled(conn, _opts) do
    if enabled?() do
      conn
    else
      conn |> send_resp(:not_found, "Not Found") |> halt()
    end
  end

  @doc "Assigns `:current_user`, or redirects to the sign-in page if nobody is signed in."
  def require_user(conn, _opts) do
    case session_user(get_session(conn)) do
      %User{} = user ->
        assign(conn, :current_user, user)

      nil ->
        conn
        |> log_out()
        |> redirect(to: ~p"/me/login")
        |> halt()
    end
  end

  ## LiveView

  @doc """
  `on_mount` hook for `/me` LiveViews, assigning `:current_user`. The plug guards the initial
  HTTP render; this guards the WebSocket connection, which doesn't go through the router.
  """
  def on_mount(:require_user, _params, session, socket) do
    case session_user(session) do
      %User{} = user ->
        {:cont, Phoenix.Component.assign(socket, :current_user, user)}

      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/me/login")}
    end
  end
end
