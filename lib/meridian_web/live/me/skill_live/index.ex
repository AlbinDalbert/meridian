defmodule MeridianWeb.Me.SkillLive.Index do
  use MeridianWeb, :live_view

  alias Meridian.{Agents, Skills}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    agents = Agents.list_agents(user)

    skills =
      Enum.map(Skills.list_available(user), fn skill ->
        %{skill: skill, agents: Enum.filter(agents, &(skill.id in &1.skills))}
      end)

    {:ok, assign(socket, page_title: "Skills", skills: skills)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.me flash={@flash} current_user={@current_user} current_path={@current_path}>
      <.header>
        Skills
        <:subtitle>
          Instructions for kinds of tasks: global skills, and your own. Turn one on for an agent
          when editing that agent; the model loads it when a task calls for it.
        </:subtitle>
        <:actions>
          <.link navigate={~p"/me/skills/new"} class="btn btn-primary">New skill</.link>
        </:actions>
      </.header>

      <.table id="skills" rows={@skills} empty="No skills available.">
        <:col :let={row} label="Name">
          <.link navigate={~p"/me/skills/#{row.skill}"}><code>{row.skill.name}</code></.link>
          <span class="badge">{if row.skill.user_id, do: "yours", else: "global"}</span>
        </:col>
        <:col :let={row} label="Description">{row.skill.description}</:col>
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
