defmodule MeridianWeb.Admin.AgentLive.Index do
  use MeridianWeb, :live_view

  alias Meridian.{Extensions, Agents}
  alias Meridian.Agents.Agent

  @impl true
  def mount(_params, _session, socket) do
    extension_names = Map.new(Extensions.list_extensions(), &{&1.id, &1.name})

    {:ok,
     assign(socket,
       page_title: "Agents",
       agents: Agents.list_all_agents(),
       extension_names: extension_names
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <.header>
        Agents
        <:subtitle>
          Every user's agents. New ones are added from the user's page, as is making one their
          default.
        </:subtitle>
      </.header>

      <.table id="agents" rows={@agents} empty="No agents yet.">
        <:col :let={agent} label="User">
          <.link navigate={~p"/admin/users/#{agent.user}"}>{agent.user.name}</.link>
        </:col>
        <:col :let={agent} label="Model id">
          <code>{Agent.model_id(agent)}</code>
          <span :if={agent.is_default} class="badge">default</span>
        </:col>
        <:col :let={agent} label="Name">{agent.name}</:col>
        <:col :let={agent} label="Upstream model"><code>{agent.model}</code></:col>
        <:col :let={agent} label="Extensions">
          {agent.extensions
          |> Map.keys()
          |> Enum.flat_map(&List.wrap(@extension_names[&1]))
          |> Enum.sort()
          |> Enum.join(", ")}
        </:col>
        <:action :let={agent}>
          <.link navigate={~p"/admin/agents/#{agent}/edit"}>Edit</.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end
end
