defmodule MeridianWeb.Me.SkillLive.Form do
  use MeridianWeb, :live_view

  alias Meridian.{Agents, Skills}
  alias Meridian.Skills.Skill

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    skill = %Skill{user_id: socket.assigns.current_user.id}
    assign(socket, page_title: "New skill", skill: skill, editable: true, agents: [])
  end

  # Global skills and the user's own: anyone else's id raises, which is a 404. Global ones can
  # be read, not edited.
  defp apply_action(socket, :edit, %{"id" => id}) do
    user = socket.assigns.current_user
    skill = Skills.get_available_skill!(user, id)

    assign(socket,
      page_title: skill.name,
      skill: skill,
      editable: skill.user_id == user.id,
      agents: user |> Agents.list_agents() |> Enum.filter(&(skill.id in &1.skills))
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.me flash={@flash} current_user={@current_user} current_path={@current_path}>
      <.header>
        {@page_title}
        <:subtitle>
          <%= cond do %>
            <% is_nil(@skill.id) -> %>
              Your own skill: only your agents can use it.
            <% @editable -> %>
              Your own skill.
            <% true -> %>
              A global skill: {@skill.description}
          <% end %>
          <span :if={@agents != []}>
            On for
            <%= for agent <- @agents do %>
              <.link navigate={~p"/me/agents/#{agent}/edit"}>{agent.name}</.link>{" "}
            <% end %>
          </span>
        </:subtitle>
      </.header>

      <%= if @editable do %>
        <.live_component
          module={MeridianWeb.SkillFormComponent}
          id="skill"
          skill={@skill}
          owner={@current_user}
          return_to={~p"/me/skills"}
          saved_path={&~p"/me/skills/#{&1}"}
        />
      <% else %>
        <pre id="skill-prompt" class="code-view prose-view">{@skill.prompt}</pre>
      <% end %>
    </Layouts.me>
    """
  end
end
