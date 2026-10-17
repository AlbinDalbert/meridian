defmodule MeridianWeb.PersonaFormComponent do
  @moduledoc """
  The persona form, shared by the admin console and `/me`. The LiveView that renders it loads
  the persona (making sure the person may edit it) and passes:

    * `persona` - the persona to edit, or a new `%Persona{}` for `user`.
    * `user` - who the persona belongs to (new personas are created for them).
    * `return_to` - where to go after saving.
    * `model_error_hint` - shown under the model field when the upstream can't be listed.
  """
  use MeridianWeb, :live_component

  alias Meridian.{Extensions, Personas, Skills, Upstream}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if socket.assigns[:form] do
        socket
      else
        socket
        |> assign(form: to_form(Personas.change_persona(socket.assigns.persona)), force: false)
        |> assign(advanced_open: false)
        |> assign_extensions()
        |> assign_skills()
        |> assign_upstream_models()
      end

    {:ok, socket}
  end

  # One row per extension the persona's user can use (the global ones and their own): whether
  # it's enabled and its settings as JSON text. The persona's settings are shown merged over the
  # defaults, so every setting is visible.
  defp assign_extensions(socket) do
    enabled = socket.assigns.persona.extensions

    rows =
      for extension <- Extensions.list_available(socket.assigns.user) do
        id = extension.id
        settings = Map.merge(Extensions.default_settings(extension), Map.get(enabled, id, %{}))

        %{
          id: id,
          name: extension.name,
          own: not is_nil(extension.user_id),
          description: Extensions.description(extension),
          enabled: Map.has_key?(enabled, id),
          settings: settings_text(settings)
        }
      end

    available = Enum.map(rows, & &1.id)
    assign(socket, extensions: rows, missing_extensions: Map.keys(enabled) -- available)
  end

  # One row per skill the persona's user can use, and whether it's on. A skill's recommended
  # extensions are checked against the extension rows as they are in the form (see
  # `skill_warning/2`).
  defp assign_skills(socket) do
    enabled = socket.assigns.persona.skills

    rows =
      for skill <- Skills.list_available(socket.assigns.user) do
        %{
          id: skill.id,
          name: skill.name,
          own: not is_nil(skill.user_id),
          description: skill.description,
          recommended: skill.recommended_extensions,
          enabled: skill.id in enabled
        }
      end

    assign(socket, skills: rows, missing_skills: enabled -- Enum.map(rows, & &1.id))
  end

  # A warning for a skill that's on without all the extensions it recommends; nothing is
  # stopped, it's only a hint.
  defp skill_warning(skill, extensions) do
    names = Map.new(extensions, &{&1.id, &1.name})
    on = for %{enabled: true, id: id} <- extensions, do: id

    case skill.recommended -- on do
      [] ->
        nil

      missing ->
        {available, gone} = Enum.split_with(missing, &Map.has_key?(names, &1))

        parts =
          Enum.map(available, &names[&1]) ++
            if(gone == [], do: [], else: ["#{length(gone)} that you can't use"])

        "Works best with #{Enum.join(parts, ", ")}, which #{if length(missing) == 1, do: "isn't", else: "aren't"} on for this persona."
    end
  end

  defp missing_text(1), do: "Settings for 1 extension that's gone"
  defp missing_text(count), do: "Settings for #{count} extensions that are gone"

  defp settings_text(settings) when map_size(settings) == 0, do: ""
  defp settings_text(settings), do: Jason.encode!(settings, pretty: true)

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
    <div>
      <.form
        for={@form}
        id="persona-form"
        class="card"
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
      >
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
          hint={if @upstream_error, do: @model_error_hint, else: "The model requests are sent to."}
          required
        />
        <.model_datalist id="upstream-models" models={@upstream_models} />
        <.input
          field={@form[:system_prompt]}
          type="textarea"
          label="System prompt"
          rows="10"
          hint="Goes before the client's own system prompt."
        />
        <fieldset class="field" id="persona-extensions">
          <legend>Extensions</legend>
          <p :if={@extensions == []} class="hint">No extensions to turn on yet.</p>
          <div :for={ext <- @extensions} class="extension">
            <.input
              type="checkbox"
              id={"extension-#{ext.id}"}
              name={"extensions[#{ext.id}][enabled]"}
              checked={ext.enabled}
              label={if ext.own, do: "#{ext.name} (own)", else: ext.name}
              description={ext.description}
            />
            <.input
              :if={ext.enabled}
              type="textarea"
              id={"extension-#{ext.id}-settings"}
              name={"extensions[#{ext.id}][settings]"}
              value={ext.settings}
              label="Settings"
              rows="3"
              spellcheck="false"
            />
          </div>
          <p :if={@missing_extensions != []} class="hint">
            {missing_text(length(@missing_extensions))} (kept, but ignored).
          </p>
          <.error :for={{message, _opts} <- @form[:extensions].errors}>{message}</.error>
        </fieldset>
        <fieldset class="field" id="persona-skills">
          <legend>Skills</legend>
          <p :if={@skills == []} class="hint">No skills to turn on yet.</p>
          <div :for={skill <- @skills} class="extension">
            <.input
              type="checkbox"
              id={"skill-#{skill.id}"}
              name={"skills[#{skill.id}]"}
              checked={skill.enabled}
              label={if skill.own, do: "#{skill.name} (own)", else: skill.name}
              description={skill.description}
            />
            <p
              :if={skill.enabled && skill_warning(skill, @extensions)}
              id={"skill-#{skill.id}-warning"}
              class="hint warning"
            >
              {skill_warning(skill, @extensions)}
            </p>
          </div>
          <p :if={@missing_skills != []} class="hint">
            {length(@missing_skills)} {if length(@missing_skills) == 1,
              do: "skill that's gone",
              else: "skills that are gone"} (kept, but ignored).
          </p>
        </fieldset>
        <%!-- Whether it's open lives on the server (toggle_advanced), so the re-render after every
             change doesn't close it, and it opens by itself to show an error inside. --%>
        <details id="persona-advanced" class="advanced" open={@advanced_open}>
          <summary phx-click="toggle_advanced" phx-target={@myself}>
            Advanced<span :if={note = advanced_note(@form, @force)} class="inline-hint">{note}</span>
          </summary>
          <.input
            field={@form[:params]}
            type="textarea"
            label="Default params"
            rows="4"
            value={params_text(@form[:params].value)}
            spellcheck="false"
            hint={~s(A JSON object of request params clients can override, e.g. {"temperature": 0.7}.)}
          />
          <.input
            type="checkbox"
            name="force"
            id="force"
            value={@force}
            label="Skip upstream model validation"
            hint="For upstreams that don't list every model, or that are temporarily down."
          />
        </details>
        <div class="form-actions">
          <.button phx-disable-with="Saving...">Save</.button>
          <.link navigate={@return_to}>Cancel</.link>
        </div>
      </.form>
    </div>
    """
  end

  # Says what's set inside, so it isn't hidden away unnoticed.
  defp advanced_note(form, force) do
    params =
      case form[:params].value do
        %{} = params when map_size(params) == 1 -> "1 default param"
        %{} = params when map_size(params) > 1 -> "#{map_size(params)} default params"
        _ -> nil
      end

    case Enum.filter([params, force && "skipping model validation"], & &1) do
      [] -> nil
      notes -> Enum.join(notes, ", ")
    end
  end

  defp params_text(params) when is_map(params) and map_size(params) == 0, do: ""
  defp params_text(params) when is_map(params), do: Jason.encode!(params, pretty: true)
  defp params_text(text) when is_binary(text), do: text
  defp params_text(_), do: ""

  @impl true
  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, update(socket, :advanced_open, &(!&1))}
  end

  def handle_event("validate", %{"persona" => params} = all, socket) do
    socket =
      socket
      |> update_extensions(all["extensions"] || %{})
      |> update_skills(all["skills"] || %{})

    params = params |> decode_params() |> put_extensions(socket) |> put_skills(socket)
    changeset = Personas.change_persona(socket.assigns.persona, params)

    {:noreply,
     socket
     |> assign(form: to_form(changeset, action: :validate), force: all["force"] == "true")
     |> open_advanced_on_error(changeset)}
  end

  def handle_event("save", %{"persona" => params} = all, socket) do
    force = all["force"] == "true"

    socket =
      socket
      |> update_extensions(all["extensions"] || %{})
      |> update_skills(all["skills"] || %{})

    params = params |> decode_params() |> put_extensions(socket) |> put_skills(socket)
    persona = socket.assigns.persona

    result =
      if persona.id,
        do: Personas.update_persona(persona, params, force: force),
        else: Personas.create_persona(socket.assigns.user, params, force: force)

    case result do
      {:ok, _persona} ->
        {:noreply,
         socket
         |> put_flash(:info, "Persona saved.")
         |> push_navigate(to: socket.assigns.return_to)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset), force: force)
         |> open_advanced_on_error(changeset)}
    end
  end

  # Errors in the advanced section can only be seen with it open.
  defp open_advanced_on_error(socket, changeset) do
    if Keyword.has_key?(changeset.errors, :params),
      do: assign(socket, advanced_open: true),
      else: socket
  end

  # Keeps the extension rows in sync with what was submitted. An extension that was just
  # switched on has no settings box yet, so it keeps the settings it was rendered with.
  defp update_extensions(socket, submitted) do
    rows =
      for ext <- socket.assigns.extensions do
        case submitted[ext.id] do
          %{} = params ->
            %{
              ext
              | enabled: params["enabled"] == "true",
                settings: params["settings"] || ext.settings
            }

          nil ->
            ext
        end
      end

    assign(socket, extensions: rows)
  end

  defp update_skills(socket, submitted) do
    rows =
      for skill <- socket.assigns.skills do
        case submitted[skill.id] do
          nil -> skill
          value -> %{skill | enabled: value == "true"}
        end
      end

    assign(socket, skills: rows)
  end

  # The persona's `skills`: the enabled rows, plus skills that are gone, which are kept.
  defp put_skills(attrs, socket) do
    enabled = for %{enabled: true, id: id} <- socket.assigns.skills, do: id
    Map.put(attrs, "skills", socket.assigns.missing_skills ++ enabled)
  end

  # The persona's `extensions`: the enabled rows with their settings, plus entries for
  # extensions that are gone, which are kept as they were. Settings that aren't a JSON
  # object are passed on as text, so the changeset rejects them.
  defp put_extensions(attrs, socket) do
    kept = Map.take(socket.assigns.persona.extensions, socket.assigns.missing_extensions)

    enabled =
      for %{enabled: true} = ext <- socket.assigns.extensions, into: %{} do
        {ext.id, decode_json_object(ext.settings)}
      end

    Map.put(attrs, "extensions", Map.merge(kept, enabled))
  end

  defp decode_json_object(text) do
    case String.trim(text) do
      "" ->
        %{}

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, map} when is_map(map) -> map
          _ -> text
        end
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
