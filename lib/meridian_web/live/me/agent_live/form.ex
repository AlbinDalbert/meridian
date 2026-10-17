defmodule MeridianWeb.Me.AgentLive.Form do
  use MeridianWeb, :live_view

  alias Meridian.Agents
  alias Meridian.Agents.Agent

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    agent = %Agent{user_id: socket.assigns.current_user.id}
    assign(socket, page_title: "New agent", agent: agent)
  end

  # Only the signed-in user's own agents: anyone else's id raises, which is a 404.
  defp apply_action(socket, :edit, %{"id" => id}) do
    agent = Agents.get_agent!(socket.assigns.current_user, id)
    assign(socket, page_title: "Edit #{agent.slug}", agent: agent)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.me flash={@flash} current_user={@current_user} current_path={@current_path}>
      <.header>{@page_title}</.header>

      <.live_component
        module={MeridianWeb.AgentFormComponent}
        id="agent"
        agent={@agent}
        user={@current_user}
        return_to={~p"/me"}
        model_error_hint="Couldn't list the upstream's models right now."
      />
    </Layouts.me>
    """
  end
end
