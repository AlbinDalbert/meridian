defmodule MeridianWeb.Me.ExtensionLive.Form do
  use MeridianWeb, :live_view

  alias Meridian.{Extensions, Personas}
  alias Meridian.Extensions.Extension

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    extension = %Extension{user_id: socket.assigns.current_user.id}

    assign(socket,
      page_title: "New extension",
      extension: extension,
      editable: true,
      last_error: nil,
      personas: []
    )
  end

  # Global extensions and the user's own: anyone else's id raises, which is a 404. Global
  # ones can be read (and exported), not edited.
  defp apply_action(socket, :edit, %{"id" => id}) do
    user = socket.assigns.current_user
    extension = Extensions.get_available_extension!(user, id)
    editable = extension.user_id == user.id
    if editable and connected?(socket), do: Extensions.subscribe(extension)

    assign(socket,
      page_title: extension.name,
      extension: extension,
      editable: editable,
      last_error: if(editable, do: Extensions.last_error(extension)),
      description: Extensions.description(extension),
      personas:
        user
        |> Personas.list_personas()
        |> Enum.filter(&Map.has_key?(&1.extensions, extension.id))
    )
  end

  @impl true
  def handle_info({:extension_error, _id, error}, socket),
    do: {:noreply, assign(socket, last_error: error)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.me flash={@flash} current_user={@current_user} current_path={@current_path}>
      <.header>
        {@page_title}
        <:subtitle>
          <%= cond do %>
            <% is_nil(@extension.id) -> %>
              Your own extension: only your personas can use it.
            <% @editable -> %>
              Your own extension.
            <% true -> %>
              A global extension: {@description}
          <% end %>
          <span :if={@personas != []}>
            On for
            <%= for persona <- @personas do %>
              <.link navigate={~p"/me/personas/#{persona}/edit"}>{persona.name}</.link>{" "}
            <% end %>
          </span>
        </:subtitle>
        <:actions :if={!@editable}>
          <.link href={~p"/me/extensions/#{@extension}/export"} class="btn btn-secondary">
            Export
          </.link>
        </:actions>
      </.header>

      <%= if @editable do %>
        <MeridianWeb.ExtensionComponents.last_error error={@last_error} />

        <.live_component
          module={MeridianWeb.ExtensionFormComponent}
          id="extension"
          extension={@extension}
          owner={@current_user}
          return_to={~p"/me/extensions"}
          saved_path={&~p"/me/extensions/#{&1}"}
          export_path={@extension.id && ~p"/me/extensions/#{@extension}/export"}
        />
      <% else %>
        <MeridianWeb.ExtensionComponents.source_view source={@extension.source} />
      <% end %>

      <MeridianWeb.ExtensionComponents.reference />
    </Layouts.me>
    """
  end
end
