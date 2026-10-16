defmodule MeridianWeb.Admin.PersonaLive.Form do
  use MeridianWeb, :live_view

  alias Meridian.{Accounts, Personas, Upstream}
  alias Meridian.Personas.Persona

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> apply_action(socket.assigns.live_action, params)
      |> assign(force: false)
      |> assign_upstream_models()

    {:ok, socket}
  end

  defp apply_action(socket, :new, %{"user_id" => user_id}) do
    user = Accounts.get_user!(user_id)
    persona = %Persona{user_id: user.id}

    socket
    |> assign(page_title: "New persona", user: user, persona: persona)
    |> assign(form: to_form(Personas.change_persona(persona)))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    persona = Personas.get_persona!(id)
    user = Accounts.get_user!(persona.user_id)

    socket
    |> assign(page_title: "Edit #{persona.slug}", user: user, persona: persona)
    |> assign(form: to_form(Personas.change_persona(persona)))
  end

  defp assign_upstream_models(socket) do
    case connected?(socket) && Upstream.list_models() do
      {:ok, models} -> assign(socket, upstream_models: models, upstream_error: nil)
      {:error, reason} -> assign(socket, upstream_models: [], upstream_error: reason)
      false -> assign(socket, upstream_models: [], upstream_error: nil)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        {@page_title}
        <:subtitle>For {@user.name}</:subtitle>
      </.header>

      <.form for={@form} id="persona-form" class="card" phx-change="validate" phx-submit="save">
        <.input
          field={@form[:slug]}
          label="Slug"
          hint={"Clients select this persona as the model meridian/#{@form[:slug].value || "<slug>"}."}
          required
        />
        <.input field={@form[:name]} label="Display name" required />
        <.input
          field={@form[:model]}
          label="Upstream model"
          list="upstream-models"
          autocomplete="off"
          hint={model_hint(@upstream_error)}
          required
        />
        <.model_datalist id="upstream-models" models={@upstream_models} />
        <.input
          type="checkbox"
          name="force"
          id="force"
          value={@force}
          label="Skip upstream model validation"
          hint="For upstreams that don't list every model, or that are temporarily down."
        />
        <.input
          field={@form[:system_prompt]}
          type="textarea"
          label="System prompt"
          rows="10"
          hint="Goes before the client's own system prompt."
        />
        <.input
          field={@form[:params]}
          type="textarea"
          label="Default params"
          rows="4"
          value={params_text(@form[:params].value)}
          spellcheck="false"
          hint={~s(A JSON object of request params clients can override, e.g. {"temperature": 0.7}.)}
        />
        <div class="form-actions">
          <.button phx-disable-with="Saving...">Save</.button>
          <.link navigate={~p"/admin/users/#{@user}"}>Cancel</.link>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  defp model_hint(nil), do: "The model requests are sent to."
  defp model_hint(_error), do: "Couldn't list upstream models; check LLM_BASE_URL."

  defp params_text(params) when is_map(params) and map_size(params) == 0, do: ""
  defp params_text(params) when is_map(params), do: Jason.encode!(params, pretty: true)
  defp params_text(text) when is_binary(text), do: text
  defp params_text(_), do: ""

  @impl true
  def handle_event("validate", %{"persona" => params} = all, socket) do
    changeset = Personas.change_persona(socket.assigns.persona, decode_params(params))

    {:noreply,
     assign(socket, form: to_form(changeset, action: :validate), force: all["force"] == "true")}
  end

  def handle_event("save", %{"persona" => params} = all, socket) do
    force = all["force"] == "true"
    params = decode_params(params)

    result =
      case socket.assigns.live_action do
        :new -> Personas.create_persona(socket.assigns.user, params, force: force)
        :edit -> Personas.update_persona(socket.assigns.persona, params, force: force)
      end

    case result do
      {:ok, _persona} ->
        {:noreply,
         socket
         |> put_flash(:info, "Persona saved.")
         |> push_navigate(to: ~p"/admin/users/#{socket.assigns.user}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset), force: force)}
    end
  end

  # The params textarea holds JSON. A valid JSON object is passed on as a map; anything else is
  # passed on as-is, so the changeset rejects it and the textarea keeps what was typed.
  defp decode_params(%{"params" => text} = attrs) when is_binary(text) do
    case String.trim(text) do
      "" ->
        Map.put(attrs, "params", %{})

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, map} when is_map(map) -> Map.put(attrs, "params", map)
          _ -> attrs
        end
    end
  end

  defp decode_params(attrs), do: attrs
end
