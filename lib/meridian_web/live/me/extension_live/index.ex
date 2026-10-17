defmodule MeridianWeb.Me.ExtensionLive.Index do
  use MeridianWeb, :live_view

  alias Meridian.{Extensions, Agents}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    agents = Agents.list_agents(user)

    extensions =
      Enum.map(Extensions.list_available(user), fn extension ->
        %{
          extension: extension,
          description: Extensions.description(extension),
          agents: Enum.filter(agents, &Map.has_key?(&1.extensions, extension.id))
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
          What your agents can use: global extensions, and your own. Turn one on for an agent, and
          change its settings, when editing that agent.
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
          <span :if={row.agents == []} class="muted">nobody yet</span>
          <%= for agent <- row.agents do %>
            <.link navigate={~p"/me/agents/#{agent}/edit"}>{agent.name}</.link>{" "}
          <% end %>
        </:col>
      </.table>
    </Layouts.me>
    """
  end
end
