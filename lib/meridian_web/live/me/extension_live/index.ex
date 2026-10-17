defmodule MeridianWeb.Me.ExtensionLive.Index do
  use MeridianWeb, :live_view

  alias Meridian.{Extensions, Personas}

  @impl true
  def mount(_params, _session, socket) do
    personas = Personas.list_personas(socket.assigns.current_user)

    extensions =
      Enum.map(Extensions.installed(), fn module ->
        %{
          name: module.name(),
          description: Extensions.description(module),
          personas: Enum.filter(personas, &Map.has_key?(&1.extensions, module.name()))
        }
      end)

    {:ok, assign(socket, page_title: "Extensions", extensions: extensions)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.me flash={@flash} current_user={@current_user} current_path={@current_path}>
      <.header>
        Extensions
        <:subtitle>
          What your crew can use. Turn one on for a persona, and change its settings, when editing
          that persona.
        </:subtitle>
      </.header>

      <.table id="extensions" rows={@extensions} empty="No extensions available.">
        <:col :let={ext} label="Name"><code>{ext.name}</code></:col>
        <:col :let={ext} label="Description">{ext.description}</:col>
        <:col :let={ext} label="On for">
          <span :if={ext.personas == []} class="muted">nobody yet</span>
          <%= for persona <- ext.personas do %>
            <.link navigate={~p"/me/personas/#{persona}/edit"}>{persona.name}</.link>{" "}
          <% end %>
        </:col>
      </.table>
    </Layouts.me>
    """
  end
end
