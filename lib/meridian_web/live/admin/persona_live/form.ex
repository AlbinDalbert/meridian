defmodule MeridianWeb.Admin.PersonaLive.Form do
  use MeridianWeb, :live_view

  alias Meridian.{Accounts, Personas}
  alias Meridian.Personas.Persona

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, %{"user_id" => user_id}) do
    user = Accounts.get_user!(user_id)
    assign(socket, page_title: "New persona", user: user, persona: %Persona{user_id: user.id})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    persona = Personas.get_persona!(id)
    user = Accounts.get_user!(persona.user_id)
    assign(socket, page_title: "Edit #{persona.slug}", user: user, persona: persona)
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
        module={MeridianWeb.PersonaFormComponent}
        id="persona"
        persona={@persona}
        user={@user}
        return_to={~p"/admin/users/#{@user}"}
        model_error_hint="Couldn't list upstream models; check LLM_BASE_URL."
      />
    </Layouts.app>
    """
  end
end
