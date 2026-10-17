defmodule MeridianWeb.ExtensionFormComponent do
  @moduledoc """
  The extension editor, shared by the admin console and `/me`: the name, the script, importing
  a script from a file, saving, and deleting. The LiveView that renders it loads the extension
  (making sure the person may edit it) and passes:

    * `extension` - the extension to edit, or a new `%Extension{}`.
    * `owner` - who a new extension belongs to (nil for a global one).
    * `return_to` - where to go after deleting.
    * `saved_path` - a function from the saved extension to where to go after saving.
    * `export_path` - where the script downloads from (nil for new extensions).

  Importing a file only fills in the editor (and the name, if it's empty); the script is
  checked when it's saved, like one typed in.
  """
  use MeridianWeb, :live_component

  alias Meridian.Extensions

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if socket.assigns[:form] do
        socket
      else
        extension = socket.assigns.extension
        attrs = if extension.id, do: %{}, else: %{"source" => Extensions.template()}

        socket
        |> assign(form: to_form(Extensions.change_extension(extension, attrs)), import_error: nil)
        |> allow_upload(:script,
          accept: :any,
          max_entries: 1,
          max_file_size: 1_000_000,
          auto_upload: true,
          progress: &handle_progress/3
        )
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.form
        for={@form}
        id="extension-form"
        class="card"
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
      >
        <.input
          field={@form[:name]}
          label="Name"
          hint="Lowercase letters, digits, '-' and '_'. Shown in lists and in persona forms."
          required
        />
        <.input
          field={@form[:source]}
          type="textarea"
          label="Script"
          class="code-editor"
          rows="28"
          spellcheck="false"
          autocomplete="off"
          phx-hook="CodeEditor"
          phx-debounce="300"
          hint="Lua. Tab indents (Esc first to leave the editor with Tab); Ctrl+S saves."
        />
        <div class="field import" phx-drop-target={@uploads.script.ref}>
          <label for={@uploads.script.ref}>Import a script</label>
          <.live_file_input upload={@uploads.script} />
          <p class="hint">
            Replaces what's in the editor; nothing is saved until you save. You can also paste a
            script in.
          </p>
          <.error :for={entry <- @uploads.script.entries} :if={!entry.valid?}>
            That file can't be imported (over 1 MB?).
          </.error>
          <.error :if={@import_error}>{@import_error}</.error>
        </div>
        <div class="form-actions">
          <.button phx-disable-with="Saving...">Save</.button>
          <.link :if={@export_path} href={@export_path} class="btn btn-secondary">Export</.link>
          <.link navigate={@return_to}>Cancel</.link>
          <button
            :if={@extension.id}
            type="button"
            class="link danger push-right"
            phx-click="delete"
            phx-target={@myself}
            data-confirm={"Delete #{@extension.name}? Personas that use it keep their settings, but it stops running."}
          >
            Delete
          </button>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"extension" => params}, socket) do
    changeset = Extensions.change_extension(socket.assigns.extension, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate), import_error: nil)}
  end

  # A file was picked; it's read when the upload is done (handle_progress).
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", %{"extension" => params}, socket) do
    extension = socket.assigns.extension

    result =
      if extension.id,
        do: Extensions.update_extension(extension, params),
        else: Extensions.create_extension(socket.assigns.owner, params)

    case result do
      {:ok, extension} ->
        {:noreply,
         socket
         |> put_flash(:info, "Extension saved.")
         |> push_navigate(to: socket.assigns.saved_path.(extension))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("delete", _params, socket) do
    {:ok, _extension} = Extensions.delete_extension(socket.assigns.extension)

    {:noreply,
     socket
     |> put_flash(:info, "Extension deleted.")
     |> push_navigate(to: socket.assigns.return_to)}
  end

  defp handle_progress(:script, %{done?: true} = entry, socket) do
    source =
      consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)

    if String.valid?(source) do
      form = socket.assigns.form
      name = form[:name].value

      params = %{
        "name" => if(name in [nil, ""], do: name_from_file(entry.client_name), else: name),
        "source" => source
      }

      changeset = Extensions.change_extension(socket.assigns.extension, params)
      {:noreply, assign(socket, form: to_form(changeset, action: :validate), import_error: nil)}
    else
      {:noreply, assign(socket, import_error: "That file isn't text.")}
    end
  end

  defp handle_progress(:script, _entry, socket), do: {:noreply, socket}

  # "My Extension.lua" -> "my-extension"
  defp name_from_file(filename) do
    filename
    |> Path.rootname()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 64)
  end
end
