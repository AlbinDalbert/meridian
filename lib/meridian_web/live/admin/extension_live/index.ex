defmodule MeridianWeb.Admin.ExtensionLive.Index do
  use MeridianWeb, :live_view

  alias Meridian.{Extensions, Personas}

  @impl true
  def mount(_params, _session, socket) do
    counts = Personas.count_by_extension()

    extensions =
      Enum.map(Extensions.list_extensions(), fn extension ->
        %{
          extension: extension,
          description: Extensions.description(extension),
          personas: Map.get(counts, extension.id, 0)
        }
      end)

    {:ok, assign(socket, page_title: "Extensions", extensions: extensions)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <.header>
        Extensions
        <:subtitle>
          Lua scripts hooked into every run of the personas that turn them on. Global ones are for
          everyone; users can also write their own.
        </:subtitle>
        <:actions>
          <.link navigate={~p"/admin/extensions/new"} class="btn btn-primary">New extension</.link>
        </:actions>
      </.header>

      <.table id="extensions" rows={@extensions} empty="No extensions yet.">
        <:col :let={row} label="Name">
          <.link navigate={~p"/admin/extensions/#{row.extension}"}>
            <code>{row.extension.name}</code>
          </.link>
        </:col>
        <:col :let={row} label="Description">{row.description}</:col>
        <:col :let={row} label="Belongs to">
          <span :if={is_nil(row.extension.user)} class="badge">global</span>
          <.link :if={row.extension.user} navigate={~p"/admin/users/#{row.extension.user}"}>
            {row.extension.user.name}
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
