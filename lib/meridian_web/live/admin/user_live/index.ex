defmodule MeridianWeb.Admin.UserLive.Index do
  use MeridianWeb, :live_view

  alias Meridian.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Users", users: Accounts.list_users())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Users
        <:subtitle>Users own personas and API keys. Clients act as a user via one of their keys.</:subtitle>
        <:actions>
          <.link navigate={~p"/admin/users/new"} class="btn btn-primary">New user</.link>
        </:actions>
      </.header>

      <.table id="users" rows={@users} empty="No users yet. Create one to get started.">
        <:col :let={user} label="Name">
          <.link navigate={~p"/admin/users/#{user}"}>{user.name}</.link>
        </:col>
        <:col :let={user} label="Email">{user.email}</:col>
        <:col :let={user} label="Created">{format_time(user.inserted_at)}</:col>
      </.table>
    </Layouts.app>
    """
  end
end
