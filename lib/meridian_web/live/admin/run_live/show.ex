defmodule MeridianWeb.Admin.RunLive.Show do
  @moduledoc """
  The live run view: a run's details, its reply as it is generated, and its event log.

  Like an API client, it subscribes to the run's events first and then replays the persisted
  ones, dropping live events it already has (by `seq`).
  """
  use MeridianWeb, :live_view

  alias Meridian.Runs
  alias Meridian.Runs.Event
  alias Meridian.Threads.Message

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    run = Runs.get_run_details!(id)
    if connected?(socket), do: Runs.subscribe(run)
    events = Runs.list_events(run)

    socket =
      socket
      |> assign(page_title: "Run", run: run, last_seq: 0, text: "", reasoning: "")
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
    |> update_text(event)
    |> stream_insert(:events, event)
  end

  defp update_text(socket, %Event{type: "message.delta", payload: payload}) do
    socket
    |> update(:text, &(&1 <> Map.get(payload, "content", "")))
    |> update(:reasoning, &(&1 <> Map.get(payload, "reasoning", "")))
  end

  defp update_text(socket, _event), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Run <code>{@run.id}</code>
        <:subtitle>
          <.link navigate={~p"/admin/threads/#{@run.thread}"}>
            {@run.thread.title || "Untitled thread"}
          </.link>
          · <.link navigate={~p"/admin/users/#{@run.thread.user}"}>{@run.thread.user.name}</.link>
        </:subtitle>
      </.header>

      <section class="card">
        <dl class="details">
          <dt>Status</dt>
          <dd><.run_status status={@run.status} /></dd>
          <dt>Persona</dt>
          <dd><code>meridian/{@run.persona_snapshot["slug"]}</code></dd>
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
          <dt :if={@run.error}>Error</dt>
          <dd :if={@run.error} class="error-text">
            <code>{@run.error["code"]}</code> {@run.error["message"]}
          </dd>
        </dl>
      </section>

      <.header level={2}>User message</.header>
      <pre class="text card">{Message.text(@run.user_message)}</pre>

      <.header level={2}>Reply</.header>
      <details :if={@reasoning != ""} open={@run.status == :running}>
        <summary class="muted">Reasoning</summary>
        <pre id="run-reasoning" class="text card">{@reasoning}</pre>
      </details>
      <pre id="run-text" class="text card">{@text}<span :if={@run.status == :running} class="cursor">▍</span></pre>

      <.header level={2}>Events</.header>
      <table>
        <thead>
          <tr>
            <th>Seq</th>
            <th>Type</th>
            <th>Payload</th>
            <th>Time</th>
          </tr>
        </thead>
        <tbody id="events" phx-update="stream">
          <tr :for={{dom_id, event} <- @streams.events} id={dom_id}>
            <td>{event.seq}</td>
            <td><code>{event.type}</code></td>
            <td><code class="payload">{format_payload(event.payload)}</code></td>
            <td class="muted">{Calendar.strftime(event.inserted_at, "%H:%M:%S.%f")}</td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end

  defp format_payload(payload) when payload == %{}, do: ""
  defp format_payload(payload), do: Jason.encode!(payload)
end
