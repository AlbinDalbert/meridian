defmodule MeridianWeb.Admin.UserLive.Show do
  use MeridianWeb, :live_view

  alias Meridian.{Accounts, Agents, Threads}
  alias Meridian.Accounts.ApiKey.Policy
  alias Meridian.Agents.Agent

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
      agents: Agents.list_agents(user),
      api_keys: Accounts.list_api_keys(user),
      activity: Threads.activity(user)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <.header>
        {@user.name}
        <:subtitle>{@user.email}</:subtitle>
        <:actions>
          <.link navigate={~p"/admin/users/#{@user}/edit"} class="btn btn-secondary">Edit</.link>
          <.button
            type="button"
            variant="danger"
            phx-click="delete_user"
            data-confirm={"Delete #{@user.name} along with their agents and API keys?"}
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
        Agents
        <:subtitle>Clients pick an agent by using its model id.</:subtitle>
        <:actions>
          <.link navigate={~p"/admin/users/#{@user}/agents/new"} class="btn btn-secondary">
            New agent
          </.link>
        </:actions>
      </.header>
      <.table id="agents" rows={@agents}>
        <:col :let={agent} label="Model id">
          <code>{Agent.model_id(agent)}</code>
          <span :if={agent.is_default} class="badge">default</span>
        </:col>
        <:col :let={agent} label="Name">{agent.name}</:col>
        <:col :let={agent} label="Upstream model"><code>{agent.model}</code></:col>
        <:action :let={agent}>
          <.link navigate={~p"/admin/agents/#{agent}/edit"}>Edit</.link>
        </:action>
        <:action :let={agent}>
          <button
            :if={not agent.is_default}
            type="button"
            class="link"
            phx-click="make_default"
            phx-value-id={agent.id}
          >
            Make default
          </button>
        </:action>
        <:action :let={agent}>
          <button
            :if={not agent.is_default}
            type="button"
            class="link danger"
            phx-click="delete_agent"
            phx-value-id={agent.id}
            data-confirm={"Delete agent #{agent.slug}?"}
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
        Activity
        <:subtitle>How much they use Meridian. What they say stays theirs.</:subtitle>
      </.header>
      <section class="card">
        <dl class="details" id="activity">
          <dt>Threads</dt>
          <dd>{@activity.thread_count}</dd>
          <dt>Messages</dt>
          <dd>{@activity.message_count}</dd>
          <dt>Runs</dt>
          <dd>{@activity.run_count}</dd>
          <dt>Tokens</dt>
          <dd>{@activity.tokens_in} in / {@activity.tokens_out} out</dd>
          <dt>Last active</dt>
          <dd>{format_time(@activity.last_active_at)}</dd>
        </dl>
      </section>
    </Layouts.app>
    """
  end

  defp policy_summary(%Policy{default_agent: default, allowed_agents: allowed}) do
    allowed_text = if allowed == [], do: "all agents", else: Enum.join(allowed, ", ")
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
    {:ok, _} = id |> user_agent!(socket) |> Agents.make_default()
    {:noreply, load_children(socket)}
  end

  def handle_event("delete_agent", %{"id" => id}, socket) do
    socket =
      case id |> user_agent!(socket) |> Agents.delete_agent() do
        {:ok, _} ->
          put_flash(socket, :info, "Agent deleted.")

        {:error, :default_agent} ->
          put_flash(socket, :error, "The default agent can't be deleted.")
      end

    {:noreply, load_children(socket)}
  end

  def handle_event("revoke_key", %{"id" => id}, socket) do
    key = Accounts.get_api_key!(id)
    true = key.user_id == socket.assigns.user.id
    {:ok, _} = Accounts.revoke_api_key(key)

    {:noreply, socket |> put_flash(:info, "API key revoked.") |> load_children()}
  end

  defp user_agent!(id, socket), do: Agents.get_agent!(socket.assigns.user, id)
end
