defmodule MeridianWeb.Admin.RunLive.Show do
  @moduledoc """
  A run's details and its event log, live. For seeing that runs work and what they cost, not
  what was said: there is no persona, no message, and no reply here, and events are shown by
  type and time only, since their payloads carry the conversation (text deltas, tool calls,
  what extensions recalled).

  Like an API client, it subscribes to the run's events first and then replays the persisted
  ones, dropping live events it already has (by `seq`).
  """
  use MeridianWeb, :live_view

  alias Meridian.Runs
  alias Meridian.Runs.Event

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    run = Runs.get_run_details!(id)
    if connected?(socket), do: Runs.subscribe(run)
    events = Runs.list_events(run)

    socket =
      socket
      |> assign(page_title: "Run", run: run, last_seq: 0)
      |> stream_configure(:events, dom_id: &"event-#{&1.seq}")
      |> stream(:events, [])

    {:ok, Enum.reduce(events, socket, &add_event/2)}
  end

  @impl true
  def handle_info({:run_event, %Event{} = event}, socket) do
    if event.seq > socket.assigns.last_seq do
      socket = add_event(event, socket)

      socket =
        if Event.terminal?(event),
          do: assign(socket, run: Runs.get_run_details!(socket.assigns.run.id)),
          else: socket

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp add_event(%Event{} = event, socket) do
    socket
    |> assign(last_seq: event.seq)
    |> stream_insert(:events, event)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Run <code>{@run.id}</code>
        <:subtitle>
          By <.link navigate={~p"/admin/users/#{@run.thread.user}"}>{@run.thread.user.name}</.link>
        </:subtitle>
      </.header>

      <section class="card">
        <dl class="details">
          <dt>Status</dt>
          <dd><.run_status status={@run.status} /></dd>
          <dt>Upstream model</dt>
          <dd><code>{@run.model}</code></dd>
          <dt>Created</dt>
          <dd>{format_time(@run.inserted_at)}</dd>
          <dt>Started</dt>
          <dd>{format_time(@run.started_at)}</dd>
          <dt>Finished</dt>
          <dd>{format_time(@run.finished_at)}</dd>
          <dt>Usage</dt>
          <dd>{format_usage(@run.usage)}</dd>
          <%!-- The code only: an upstream's error message can quote the request. --%>
          <dt :if={@run.error}>Error</dt>
          <dd :if={@run.error} class="error-text"><code>{@run.error["code"]}</code></dd>
        </dl>
      </section>

      <.header level={2}>
        Events
        <:subtitle>What happened, by type. Their contents aren't shown.</:subtitle>
      </.header>
      <table>
        <thead>
          <tr>
            <th>Seq</th>
            <th>Type</th>
            <th>Time</th>
          </tr>
        </thead>
        <tbody id="events" phx-update="stream">
          <tr :for={{dom_id, event} <- @streams.events} id={dom_id}>
            <td>{event.seq}</td>
            <td><code>{event.type}</code></td>
            <td class="muted">{Calendar.strftime(event.inserted_at, "%H:%M:%S.%f")}</td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end
end
