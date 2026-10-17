defmodule MeridianWeb.Me.ExtensionLive.Index do
  use MeridianWeb, :live_view

  alias Meridian.{Extensions, Personas}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    personas = Personas.list_personas(user)

    extensions =
      Enum.map(Extensions.list_available(user), fn extension ->
        %{
          extension: extension,
          description: Extensions.description(extension),
          personas: Enum.filter(personas, &Map.has_key?(&1.extensions, extension.id))
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
          What your crew can use: global extensions, and your own. Turn one on for a persona, and
          change its settings, when editing that persona.
        </:subtitle>
        <:actions>
          <.link navigate={~p"/me/extensions/new"} class="btn btn-primary">New extension</.link>
        </:actions>
      </.header>

      <.table id="extensions" rows={@extensions} empty="No extensions available.">
        <:col :let={row} label="Name">
          <.link navigate={~p"/me/extensions/#{row.extension}"}>
            <code>{row.extension.name}</code>
          </.link>
          <span class="badge">{if row.extension.user_id, do: "yours", else: "global"}</span>
        </:col>
        <:col :let={row} label="Description">{row.description}</:col>
        <:col :let={row} label="On for">
          <span :if={row.personas == []} class="muted">nobody yet</span>
          <%= for persona <- row.personas do %>
            <.link navigate={~p"/me/personas/#{persona}/edit"}>{persona.name}</.link>{" "}
          <% end %>
        </:col>
      </.table>
    </Layouts.me>
    """
  end
end
