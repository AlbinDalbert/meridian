defmodule MeridianWeb.Admin.AgentLive.Form do
  use MeridianWeb, :live_view

  alias Meridian.{Accounts, Agents}
  alias Meridian.Agents.Agent

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, %{"user_id" => user_id}) do
    user = Accounts.get_user!(user_id)
    assign(socket, page_title: "New agent", user: user, agent: %Agent{user_id: user.id})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    agent = Agents.get_agent!(id)
    user = Accounts.get_user!(agent.user_id)
    assign(socket, page_title: "Edit #{agent.slug}", user: user, agent: agent)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <.header>
        {@page_title}
        <:subtitle>For {@user.name}</:subtitle>
      </.header>

      <.live_component
        module={MeridianWeb.AgentFormComponent}
        id="agent"
        agent={@agent}
        user={@user}
        return_to={~p"/admin/users/#{@user}"}
        model_error_hint="Couldn't list upstream models; check LLM_BASE_URL."
      />
    </Layouts.app>
    """
  end
end
