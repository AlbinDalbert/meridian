defmodule MeridianWeb.Me.PersonaLive.Form do
  use MeridianWeb, :live_view

  alias Meridian.Personas
  alias Meridian.Personas.Persona

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    persona = %Persona{user_id: socket.assigns.current_user.id}
    assign(socket, page_title: "New persona", persona: persona)
  end

  # Only the signed-in user's own personas: anyone else's id raises, which is a 404.
  defp apply_action(socket, :edit, %{"id" => id}) do
    persona = Personas.get_persona!(socket.assigns.current_user, id)
    assign(socket, page_title: "Edit #{persona.slug}", persona: persona)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.me flash={@flash} current_user={@current_user}>
      <.header>{@page_title}</.header>

      <.live_component
        module={MeridianWeb.PersonaFormComponent}
        id="persona"
        persona={@persona}
        user={@current_user}
        return_to={~p"/me"}
        model_error_hint="Couldn't list the upstream's models right now."
      />
    </Layouts.me>
    """
  end
end
