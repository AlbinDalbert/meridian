defmodule MeridianWeb.Admin.ExtensionLive.Index do
  use MeridianWeb, :live_view

  alias Meridian.{Extensions, Personas}

  @impl true
  def mount(_params, _session, socket) do
    counts = Personas.count_by_extension()

    extensions =
      Enum.map(Extensions.installed(), fn module ->
        %{
          name: module.name(),
          description: Extensions.description(module),
          personas: Map.get(counts, module.name(), 0)
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
          Installed in this deployment (<code>config :meridian, :extensions</code>). Each persona
          turns them on for itself.
        </:subtitle>
      </.header>

      <.table id="extensions" rows={@extensions} empty="No extensions installed.">
        <:col :let={ext} label="Name"><code>{ext.name}</code></:col>
        <:col :let={ext} label="Description">{ext.description}</:col>
        <:col :let={ext} label="Enabled on">{personas_text(ext.personas)}</:col>
      </.table>
    </Layouts.app>
    """
  end

  defp personas_text(1), do: "1 persona"
  defp personas_text(count), do: "#{count} personas"
end
