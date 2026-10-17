defmodule MeridianWeb.Me.AgentLive.Index do
  use MeridianWeb, :live_view

  alias Meridian.Agents
  alias Meridian.Agents.Agent

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Agents") |> load_agents()}
  end

  defp load_agents(socket) do
    assign(socket, agents: Agents.list_agents(socket.assigns.current_user))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.me flash={@flash} current_user={@current_user} current_path={@current_path}>
      <.header>
        Your agents
        <:subtitle>
          Clients pick an agent by using its model id. Threads without one use your default.
        </:subtitle>
        <:actions>
          <.link navigate={~p"/me/agents/new"} class="btn btn-secondary">New agent</.link>
        </:actions>
      </.header>
      <.table id="agents" rows={@agents}>
        <:col :let={agent} label="Model id">
          <code>{Agent.model_id(agent)}</code>
          <span :if={agent.is_default} class="badge">default</span>
        </:col>
        <:col :let={agent} label="Name">{agent.name}</:col>
        <:col :let={agent} label="Upstream model"><code>{agent.model}</code></:col>
        <:action :let={agent}>
          <.link navigate={~p"/me/agents/#{agent}/edit"}>Edit</.link>
        </:action>
        <:action :let={agent}>
          <button
            :if={not agent.is_default}
            type="button"
            class="link"
            phx-click="make_default"
            phx-value-id={agent.id}
          >
            Make default
          </button>
        </:action>
        <:action :let={agent}>
          <button
            :if={not agent.is_default}
            type="button"
            class="link danger"
            phx-click="delete_agent"
            phx-value-id={agent.id}
            data-confirm={"Delete agent #{agent.slug}?"}
          >
            Delete
          </button>
        </:action>
      </.table>
    </Layouts.me>
    """
  end

  @impl true
  def handle_event("make_default", %{"id" => id}, socket) do
    {:ok, _} = socket.assigns.current_user |> Agents.get_agent!(id) |> Agents.make_default()
    {:noreply, load_agents(socket)}
  end

  def handle_event("delete_agent", %{"id" => id}, socket) do
    socket =
      case socket.assigns.current_user
           |> Agents.get_agent!(id)
           |> Agents.delete_agent() do
        {:ok, _} -> put_flash(socket, :info, "Agent deleted.")
        {:error, :default_agent} -> put_flash(socket, :error, "Your default can't be deleted.")
      end

    {:noreply, load_agents(socket)}
  end
end
