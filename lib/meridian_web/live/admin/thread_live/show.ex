defmodule MeridianWeb.Admin.ThreadLive.Show do
  use MeridianWeb, :live_view

  alias Meridian.{Runs, Threads}
  alias Meridian.Personas.Persona
  alias Meridian.Threads.Message

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    thread = Threads.get_thread!(id)
    if connected?(socket), do: Runs.subscribe_thread(thread)

    {:ok,
     socket
     |> assign(page_title: thread.title || "Thread", thread: thread)
     |> load_children()}
  end

  defp load_children(socket) do
    thread = socket.assigns.thread
    assign(socket, messages: Threads.list_all_messages(thread), runs: Runs.list_runs(thread))
  end

  @impl true
  def handle_info({:run_event, event}, socket) do
    # Deltas are shown on the run page; here only the outcome matters.
    if event.type == "message.delta",
      do: {:noreply, socket},
      else: {:noreply, load_children(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        {@thread.title || "Untitled thread"}
        <:subtitle>
          <.link navigate={~p"/admin/users/#{@thread.user}"}>{@thread.user.name}</.link>
          · <code :if={@thread.persona}>{Persona.model_id(@thread.persona)}</code>
          <span :if={is_nil(@thread.persona)}>persona deleted</span>
          · created {format_time(@thread.inserted_at)}
        </:subtitle>
      </.header>

      <.header level={2}>Messages</.header>
      <p :if={@messages == []} class="muted">No messages yet.</p>
      <div class="messages">
        <article :for={message <- @messages} class={"message message-#{message.role}"}>
          <header>
            <span class="badge">{message.role}</span>
            <span class="muted">{format_time(message.inserted_at)}</span>
            <.link :if={message.run_id} navigate={~p"/admin/runs/#{message.run_id}"}>run</.link>
            <span :if={message.metadata["finish_reason"]} class="muted">
              {message.metadata["finish_reason"]}
            </span>
          </header>
          <details :if={Message.reasoning(message) != ""}>
            <summary class="muted">Reasoning</summary>
            <pre class="text">{Message.reasoning(message)}</pre>
          </details>
          <pre class="text">{Message.text(message)}</pre>
        </article>
      </div>

      <.header level={2}>Runs</.header>
      <.run_table id="thread-runs" runs={@runs} />
    </Layouts.app>
    """
  end
end
