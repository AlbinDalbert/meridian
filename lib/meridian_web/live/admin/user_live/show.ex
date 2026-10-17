defmodule MeridianWeb.Admin.UserLive.Show do
  use MeridianWeb, :live_view

  alias Meridian.{Accounts, Personas, Threads}
  alias Meridian.Accounts.ApiKey.Policy
  alias Meridian.Personas.Persona

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = Accounts.get_user!(id)

    {:ok,
     socket
     |> assign(page_title: user.name, user: user)
     |> load_children()}
  end

  defp load_children(socket) do
    user = socket.assigns.user

    assign(socket,
      personas: Personas.list_personas(user),
      api_keys: Accounts.list_api_keys(user),
      threads: Threads.list_threads(user)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        {@user.name}
        <:subtitle>{@user.email}</:subtitle>
        <:actions>
          <.link navigate={~p"/admin/users/#{@user}/edit"} class="btn btn-secondary">Edit</.link>
          <.button
            type="button"
            variant="danger"
            phx-click="delete_user"
            data-confirm={"Delete #{@user.name} along with their personas and API keys?"}
          >
            Delete
          </.button>
        </:actions>
      </.header>

      <p :if={@user.oidc_subject} class="muted">
        Signs in through the OIDC provider as <code>{@user.oidc_subject}</code>.
        <button
          type="button"
          class="link danger"
          phx-click="unlink_sign_in"
          data-confirm={"Unlink #{@user.name}'s sign-in? Their next sign-in links again by email."}
        >
          Unlink
        </button>
      </p>

      <.header level={2}>
        Personas
        <:subtitle>Clients pick a persona by using its model id.</:subtitle>
        <:actions>
          <.link navigate={~p"/admin/users/#{@user}/personas/new"} class="btn btn-secondary">
            New persona
          </.link>
        </:actions>
      </.header>
      <.table id="personas" rows={@personas}>
        <:col :let={persona} label="Model id">
          <code>{Persona.model_id(persona)}</code>
          <span :if={persona.is_default} class="badge">default</span>
        </:col>
        <:col :let={persona} label="Name">{persona.name}</:col>
        <:col :let={persona} label="Upstream model"><code>{persona.model}</code></:col>
        <:action :let={persona}>
          <.link navigate={~p"/admin/personas/#{persona}/edit"}>Edit</.link>
        </:action>
        <:action :let={persona}>
          <button
            :if={not persona.is_default}
            type="button"
            class="link"
            phx-click="make_default"
            phx-value-id={persona.id}
          >
            Make default
          </button>
        </:action>
        <:action :let={persona}>
          <button
            :if={not persona.is_default}
            type="button"
            class="link danger"
            phx-click="delete_persona"
            phx-value-id={persona.id}
            data-confirm={"Delete persona #{persona.slug}?"}
          >
            Delete
          </button>
        </:action>
      </.table>

      <.header level={2}>
        API keys
        <:subtitle>Each client or purpose should get its own key.</:subtitle>
        <:actions>
          <.link navigate={~p"/admin/users/#{@user}/keys/new"} class="btn btn-secondary">
            Mint API key
          </.link>
        </:actions>
      </.header>
      <.table id="api-keys" rows={@api_keys} empty="No API keys yet.">
        <:col :let={key} label="Name">{key.name}</:col>
        <:col :let={key} label="Key"><code>{key.prefix}…</code></:col>
        <:col :let={key} label="Policy">{policy_summary(key.policy)}</:col>
        <:col :let={key} label="Last used">{format_time(key.last_used_at)}</:col>
        <:col :let={key} label="Status">
          <span :if={key.revoked_at} class="badge">revoked {format_time(key.revoked_at)}</span>
          <span :if={is_nil(key.revoked_at)}>active</span>
        </:col>
        <:action :let={key}>
          <.link :if={is_nil(key.revoked_at)} navigate={~p"/admin/keys/#{key}/edit"}>Edit</.link>
        </:action>
        <:action :let={key}>
          <button
            :if={is_nil(key.revoked_at)}
            type="button"
            class="link danger"
            phx-click="revoke_key"
            phx-value-id={key.id}
            data-confirm={"Revoke #{key.name}? Clients using it will stop working immediately."}
          >
            Revoke
          </button>
        </:action>
      </.table>

      <.header level={2}>
        Threads
        <:subtitle>Conversations on the native API, most recently active first.</:subtitle>
      </.header>
      <.table id="threads" rows={@threads} empty="No threads yet.">
        <:col :let={thread} label="Title">
          <.link navigate={~p"/admin/threads/#{thread}"}>{thread.title || "Untitled"}</.link>
        </:col>
        <:col :let={thread} label="Persona">
          <code :if={thread.persona}>{Persona.model_id(thread.persona)}</code>
        </:col>
        <:col :let={thread} label="Last active">{format_time(thread.updated_at)}</:col>
      </.table>
    </Layouts.app>
    """
  end

  defp policy_summary(%Policy{default_persona: default, allowed_personas: allowed}) do
    allowed_text = if allowed == [], do: "all personas", else: Enum.join(allowed, ", ")
    default_text = if default, do: "; default #{default}", else: ""
    allowed_text <> default_text
  end

  @impl true
  def handle_event("delete_user", _params, socket) do
    {:ok, _} = Accounts.delete_user(socket.assigns.user)

    {:noreply,
     socket
     |> put_flash(:info, "User deleted.")
     |> push_navigate(to: ~p"/admin/users")}
  end

  def handle_event("unlink_sign_in", _params, socket) do
    {:ok, user} = Accounts.unlink_oidc_identity(socket.assigns.user)
    {:noreply, socket |> assign(user: user) |> put_flash(:info, "Sign-in unlinked.")}
  end

  def handle_event("make_default", %{"id" => id}, socket) do
    {:ok, _} = id |> user_persona!(socket) |> Personas.make_default()
    {:noreply, load_children(socket)}
  end

  def handle_event("delete_persona", %{"id" => id}, socket) do
    socket =
      case id |> user_persona!(socket) |> Personas.delete_persona() do
        {:ok, _} ->
          put_flash(socket, :info, "Persona deleted.")

        {:error, :default_persona} ->
          put_flash(socket, :error, "The default persona can't be deleted.")
      end

    {:noreply, load_children(socket)}
  end

  def handle_event("revoke_key", %{"id" => id}, socket) do
    key = Accounts.get_api_key!(id)
    true = key.user_id == socket.assigns.user.id
    {:ok, _} = Accounts.revoke_api_key(key)

    {:noreply, socket |> put_flash(:info, "API key revoked.") |> load_children()}
  end

  defp user_persona!(id, socket) do
    persona = Personas.get_persona!(id)
    true = persona.user_id == socket.assigns.user.id
    persona
  end
end
