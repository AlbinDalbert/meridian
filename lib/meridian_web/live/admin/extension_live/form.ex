defmodule MeridianWeb.Admin.ExtensionLive.Form do
  use MeridianWeb, :live_view

  alias Meridian.{Extensions, Agents}
  alias Meridian.Extensions.Extension

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      page_title: "New extension",
      extension: %Extension{},
      last_error: nil,
      tools: %{}
    )
  end

  # Admins can edit every extension, users' own included.
  defp apply_action(socket, :edit, %{"id" => id}) do
    extension = Extensions.get_extension!(id)
    if connected?(socket), do: Extensions.subscribe(extension)

    assign(socket,
      page_title: extension.name,
      extension: extension,
      last_error: Extensions.last_error(extension),
      tools: Extensions.tools(extension),
      agents: Map.get(Agents.count_by_extension(), extension.id, 0)
    )
  end

  @impl true
  def handle_info({:extension_error, _id, error}, socket),
    do: {:noreply, assign(socket, last_error: error)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <.header>
        {@page_title}
        <:subtitle :if={is_nil(@extension.id)}>
          A global extension: every user can turn it on for their agents.
        </:subtitle>
        <:subtitle :if={@extension.id}>
          <%= if @extension.user do %>
            Belongs to
            <.link navigate={~p"/admin/users/#{@extension.user}"}>{@extension.user.name}</.link>.
          <% else %>
            Global.
          <% end %>
          Enabled on {@agents} {if @agents == 1, do: "agent", else: "agents"}.
        </:subtitle>
      </.header>

      <MeridianWeb.ExtensionComponents.last_error error={@last_error} />
      <MeridianWeb.ExtensionComponents.tools tools={@tools} />

      <.live_component
        module={MeridianWeb.ExtensionFormComponent}
        id="extension"
        extension={@extension}
        owner={nil}
        return_to={~p"/admin/extensions"}
        saved_path={&~p"/admin/extensions/#{&1}"}
        export_path={@extension.id && ~p"/admin/extensions/#{@extension}/export"}
      />

      <MeridianWeb.ExtensionComponents.reference />
    </Layouts.app>
    """
  end
end
