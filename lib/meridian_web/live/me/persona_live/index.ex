defmodule MeridianWeb.Me.PersonaLive.Index do
  use MeridianWeb, :live_view

  alias Meridian.Personas
  alias Meridian.Personas.Persona

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Personas") |> load_personas()}
  end

  defp load_personas(socket) do
    assign(socket, personas: Personas.list_personas(socket.assigns.current_user))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.me flash={@flash} current_user={@current_user}>
      <.header>
        Your personas
        <:subtitle>
          Clients pick a persona by using its model id. Threads without one use your default.
        </:subtitle>
        <:actions>
          <.link navigate={~p"/me/personas/new"} class="btn btn-secondary">New persona</.link>
        </:actions>
      </.header>
      <.table id="personas" rows={@personas}>
        <:col :let={persona} label="Model id">
          <code>{Persona.model_id(persona)}</code>
          <span :if={persona.is_default} class="badge">default</span>
        </:col>
        <:col :let={persona} label="Name">{persona.name}</:col>
        <:col :let={persona} label="Upstream model"><code>{persona.model}</code></:col>
        <:action :let={persona}>
          <.link navigate={~p"/me/personas/#{persona}/edit"}>Edit</.link>
        </:action>
        <:action :let={persona}>
          <button
            :if={not persona.is_default}
            type="button"
            class="link"
            phx-click="make_default"
            phx-value-id={persona.id}
          >
            Make default
          </button>
        </:action>
        <:action :let={persona}>
          <button
            :if={not persona.is_default}
            type="button"
            class="link danger"
            phx-click="delete_persona"
            phx-value-id={persona.id}
            data-confirm={"Delete persona #{persona.slug}?"}
          >
            Delete
          </button>
        </:action>
      </.table>
    </Layouts.me>
    """
  end

  @impl true
  def handle_event("make_default", %{"id" => id}, socket) do
    {:ok, _} = socket.assigns.current_user |> Personas.get_persona!(id) |> Personas.make_default()
    {:noreply, load_personas(socket)}
  end

  def handle_event("delete_persona", %{"id" => id}, socket) do
    socket =
      case socket.assigns.current_user
           |> Personas.get_persona!(id)
           |> Personas.delete_persona() do
        {:ok, _} -> put_flash(socket, :info, "Persona deleted.")
        {:error, :default_persona} -> put_flash(socket, :error, "Your default can't be deleted.")
      end

    {:noreply, load_personas(socket)}
  end
end
