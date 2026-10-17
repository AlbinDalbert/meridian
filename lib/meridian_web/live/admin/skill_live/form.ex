defmodule MeridianWeb.Admin.SkillLive.Form do
  use MeridianWeb, :live_view

  alias Meridian.{Agents, Skills}
  alias Meridian.Skills.Skill

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    assign(socket, page_title: "New skill", skill: %Skill{}, owner: nil)
  end

  # Admins can edit every skill, users' own included.
  defp apply_action(socket, :edit, %{"id" => id}) do
    skill = Skills.get_skill!(id)

    assign(socket,
      page_title: skill.name,
      skill: skill,
      owner: skill.user,
      agents: Map.get(Agents.count_by_skill(), skill.id, 0)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <.header>
        {@page_title}
        <:subtitle :if={is_nil(@skill.id)}>
          A global skill: every user can turn it on for their agents.
        </:subtitle>
        <:subtitle :if={@skill.id}>
          <%= if @skill.user do %>
            Belongs to <.link navigate={~p"/admin/users/#{@skill.user}"}>{@skill.user.name}</.link>.
          <% else %>
            Global.
          <% end %>
          Enabled on {@agents} {if @agents == 1, do: "agent", else: "agents"}.
        </:subtitle>
      </.header>

      <.live_component
        module={MeridianWeb.SkillFormComponent}
        id="skill"
        skill={@skill}
        owner={@owner}
        return_to={~p"/admin/skills"}
        saved_path={&~p"/admin/skills/#{&1}"}
      />
    </Layouts.app>
    """
  end
end
