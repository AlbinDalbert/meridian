defmodule MeridianWeb.Me.SkillLive.Form do
  use MeridianWeb, :live_view

  alias Meridian.{Personas, Skills}
  alias Meridian.Skills.Skill

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    skill = %Skill{user_id: socket.assigns.current_user.id}
    assign(socket, page_title: "New skill", skill: skill, editable: true, personas: [])
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
      personas: user |> Personas.list_personas() |> Enum.filter(&(skill.id in &1.skills))
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
              Your own skill: only your personas can use it.
            <% @editable -> %>
              Your own skill.
            <% true -> %>
              A global skill: {@skill.description}
          <% end %>
          <span :if={@personas != []}>
            On for
            <%= for persona <- @personas do %>
              <.link navigate={~p"/me/personas/#{persona}/edit"}>{persona.name}</.link>{" "}
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
