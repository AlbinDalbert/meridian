defmodule MeridianWeb.Admin.AccessRequestLive.Index do
  @moduledoc """
  Requests to be added, left on the public request page. Accepting creates the user, with a
  default persona on the model set at the top of the page; snoozing moves a request to "Later";
  rejecting moves it to "Rejected", from where it can be restored.
  """
  use MeridianWeb, :live_view

  alias Meridian.{AccessRequests, Personas, Upstream}

  @impl true
  def mount(_params, _session, socket) do
    upstream_models =
      case connected?(socket) && Upstream.list_models() do
        {:ok, models} -> models
        _ -> []
      end

    {:ok,
     socket
     |> assign(page_title: "Requests", upstream_models: upstream_models, force: false)
     |> assign(model: Personas.newest_default_model() || "")
     |> load_requests()}
  end

  defp load_requests(socket) do
    assign(socket,
      pending: AccessRequests.list_requests("pending"),
      snoozed: AccessRequests.list_requests("snoozed"),
      rejected: AccessRequests.list_requests("rejected")
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <.header>
        Requests
        <:subtitle>
          People asking to be added, from <.link href={~p"/me/request"}>the request page</.link>.
        </:subtitle>
      </.header>

      <.form for={%{}} id="accept-settings" class="card" phx-change="settings">
        <.input
          name="model"
          id="accept-model"
          value={@model}
          label="Model for new users' default persona"
          list="upstream-models"
          autocomplete="off"
          hint="Accepting someone creates their user with a default persona on this model."
        />
        <.model_datalist id="upstream-models" models={@upstream_models} />
        <.input
          type="checkbox"
          name="force"
          id="accept-force"
          value={@force}
          label="Skip upstream model validation"
        />
      </.form>

      <div id="pending-requests" class="request-list">
        <p :if={@pending == []} class="muted">No requests waiting.</p>
        <.request_card :for={request <- @pending} request={request}>
          <.button phx-click="accept" phx-value-id={request.id}>Accept</.button>
          <.button variant="secondary" phx-click="snooze" phx-value-id={request.id}>
            Snooze
          </.button>
          <.button
            variant="danger"
            phx-click="reject"
            phx-value-id={request.id}
            data-confirm={"Reject #{request.email}?"}
          >
            Reject
          </.button>
        </.request_card>
      </div>

      <.header :if={@snoozed != []} level={2}>
        Later
        <:subtitle>Snoozed, to look at later.</:subtitle>
      </.header>
      <div :if={@snoozed != []} id="snoozed-requests" class="request-list">
        <.request_card :for={request <- @snoozed} request={request}>
          <.button phx-click="accept" phx-value-id={request.id}>Accept</.button>
          <.button variant="secondary" phx-click="restore" phx-value-id={request.id}>
            Unsnooze
          </.button>
          <.button
            variant="danger"
            phx-click="reject"
            phx-value-id={request.id}
            data-confirm={"Reject #{request.email}?"}
          >
            Reject
          </.button>
        </.request_card>
      </div>

      <details :if={@rejected != []} id="rejected-requests" class="rejected">
        <summary class="muted">Rejected ({length(@rejected)})</summary>
        <div class="request-list">
          <.request_card :for={request <- @rejected} request={request}>
            <.button variant="secondary" phx-click="restore" phx-value-id={request.id}>
              Restore
            </.button>
          </.request_card>
        </div>
      </details>
    </Layouts.app>
    """
  end

  attr :request, :map, required: true
  slot :inner_block, required: true

  defp request_card(assigns) do
    ~H"""
    <div class="request-card" id={"request-#{@request.id}"}>
      <div class="request-who">
        <div class="request-email">{@request.email}</div>
        <div :if={@request.name} class="request-name">{@request.name}</div>
        <div class="hint">
          {asked(@request)}<span :if={@request.status != "pending"}>
            · {@request.status} {format_time(@request.status_changed_at)}</span>
        </div>
      </div>
      <div class="actions">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  defp asked(%{times_requested: 1} = request), do: "Asked #{format_time(request.requested_at)}"

  defp asked(request),
    do: "Asked #{request.times_requested} times, last #{format_time(request.requested_at)}"

  @impl true
  def handle_event("settings", params, socket) do
    {:noreply, assign(socket, model: params["model"] || "", force: params["force"] == "true")}
  end

  def handle_event("accept", %{"id" => id}, socket) do
    request = AccessRequests.get_request!(id)

    socket =
      case AccessRequests.accept(request, %{"model" => socket.assigns.model},
             force: socket.assigns.force
           ) do
        {:ok, user} ->
          put_flash(socket, :info, "Added #{user.email}. They can sign in now.")

        {:error, kind, changeset} ->
          put_flash(socket, :error, "Couldn't add #{request.email}: #{describe(kind, changeset)}")
      end

    {:noreply, load_requests(socket)}
  end

  def handle_event("snooze", %{"id" => id}, socket) do
    {:ok, _} = id |> AccessRequests.get_request!() |> AccessRequests.snooze()
    {:noreply, load_requests(socket)}
  end

  def handle_event("reject", %{"id" => id}, socket) do
    {:ok, _} = id |> AccessRequests.get_request!() |> AccessRequests.reject()
    {:noreply, load_requests(socket)}
  end

  def handle_event("restore", %{"id" => id}, socket) do
    {:ok, _} = id |> AccessRequests.get_request!() |> AccessRequests.restore()
    {:noreply, load_requests(socket)}
  end

  defp describe(kind, changeset) do
    label = if kind == :persona, do: "the default persona's ", else: ""

    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{label}#{field} #{Enum.join(messages, ", ")}"
    end)
  end
end
