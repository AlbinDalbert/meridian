defmodule MeridianWeb.Nav do
  @moduledoc """
  `on_mount` hook for the admin console and `/me`: assigns `:current_path` on every navigation,
  so the sidebar (see `MeridianWeb.Layouts`) can mark the page you're on.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     attach_hook(socket, :current_path, :handle_params, fn _params, uri, socket ->
       {:cont, assign(socket, :current_path, URI.parse(uri).path)}
     end)}
  end
end
