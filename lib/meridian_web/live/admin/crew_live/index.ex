defmodule MeridianWeb.Admin.CrewLive.Index do
  use MeridianWeb, :live_view

  alias Meridian.Personas
  alias Meridian.Personas.Persona

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Crew", personas: Personas.list_all_personas())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <.header>
        Crew
        <:subtitle>
          Every user's personas. New ones are added from the user's page, as is making one their
          default.
        </:subtitle>
      </.header>

      <.table id="crew" rows={@personas} empty="No personas yet.">
        <:col :let={persona} label="User">
          <.link navigate={~p"/admin/users/#{persona.user}"}>{persona.user.name}</.link>
        </:col>
        <:col :let={persona} label="Model id">
          <code>{Persona.model_id(persona)}</code>
          <span :if={persona.is_default} class="badge">default</span>
        </:col>
        <:col :let={persona} label="Name">{persona.name}</:col>
        <:col :let={persona} label="Upstream model"><code>{persona.model}</code></:col>
        <:col :let={persona} label="Extensions">
          {persona.extensions |> Map.keys() |> Enum.sort() |> Enum.join(", ")}
        </:col>
        <:action :let={persona}>
          <.link navigate={~p"/admin/personas/#{persona}/edit"}>Edit</.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end
end
