defmodule MeridianWeb.Admin.RunLive.Index do
  use MeridianWeb, :live_view

  alias Meridian.Runs

  @limit 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe_all()
    {:ok, assign(socket, page_title: "Runs", runs: Runs.list_recent_runs(@limit))}
  end

  @impl true
  def handle_info({:run_updated, _run}, socket) do
    {:noreply, assign(socket, runs: Runs.list_recent_runs(@limit))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Runs
        <:subtitle>The {length(@runs)} most recent runs across all users. Updates live.</:subtitle>
      </.header>

      <.run_table id="runs" runs={@runs} show_user />
    </Layouts.app>
    """
  end
end
