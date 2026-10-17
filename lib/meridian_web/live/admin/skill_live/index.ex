defmodule MeridianWeb.Admin.SkillLive.Index do
  use MeridianWeb, :live_view

  alias Meridian.{Personas, Skills}

  @impl true
  def mount(_params, _session, socket) do
    counts = Personas.count_by_skill()

    skills =
      Enum.map(Skills.list_skills(), fn skill ->
        %{skill: skill, personas: Map.get(counts, skill.id, 0)}
      end)

    {:ok, assign(socket, page_title: "Skills", skills: skills)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <.header>
        Skills
        <:subtitle>
          Instructions for kinds of tasks. Personas that turn a skill on tell the model about it,
          and the model loads it when a task calls for it. Global ones are for everyone; users can
          also write their own.
        </:subtitle>
        <:actions>
          <.link navigate={~p"/admin/skills/new"} class="btn btn-primary">New skill</.link>
        </:actions>
      </.header>

      <.table id="skills" rows={@skills} empty="No skills yet.">
        <:col :let={row} label="Name">
          <.link navigate={~p"/admin/skills/#{row.skill}"}><code>{row.skill.name}</code></.link>
        </:col>
        <:col :let={row} label="Description">{row.skill.description}</:col>
        <:col :let={row} label="Belongs to">
          <span :if={is_nil(row.skill.user)} class="badge">global</span>
          <.link :if={row.skill.user} navigate={~p"/admin/users/#{row.skill.user}"}>
            {row.skill.user.name}
          </.link>
        </:col>
        <:col :let={row} label="Enabled on">{personas_text(row.personas)}</:col>
      </.table>
    </Layouts.app>
    """
  end

  defp personas_text(1), do: "1 persona"
  defp personas_text(count), do: "#{count} personas"
end
