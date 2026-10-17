defmodule MeridianWeb.Admin.ApiKeyLive.Form do
  use MeridianWeb, :live_view

  alias Meridian.{Accounts, Personas}
  alias Meridian.Accounts.ApiKey

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, %{"user_id" => user_id}) do
    user = Accounts.get_user!(user_id)
    api_key = %ApiKey{user_id: user.id}

    socket
    |> assign(page_title: "Mint API key", user: user, api_key: api_key, minted: nil)
    |> assign_personas()
    |> assign(form: to_form(Accounts.change_api_key(api_key)))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    api_key = Accounts.get_api_key!(id)
    user = Accounts.get_user!(api_key.user_id)

    socket
    |> assign(page_title: "Edit #{api_key.name}", user: user, api_key: api_key, minted: nil)
    |> assign_personas()
    |> assign(form: to_form(Accounts.change_api_key(api_key)))
  end

  defp assign_personas(socket) do
    slugs = socket.assigns.user |> Personas.list_personas() |> Enum.map(& &1.slug)
    assign(socket, persona_options: Enum.map(slugs, &{&1, &1}))
  end

  @impl true
  def render(%{minted: %ApiKey{}} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <.header>
        API key minted
        <:subtitle>For {@user.name}: {@minted.name}</:subtitle>
      </.header>
      <section class="card">
        <p>Copy the key now. It is stored only as a hash and can't be shown again.</p>
        <code id="minted-token" class="secret">{@minted.token}</code>
        <p class="muted">
          Point an OpenAI-compatible client at this server's <code>/v1</code> and use the key as
          its API key.
        </p>
        <div class="form-actions">
          <.link navigate={~p"/admin/users/#{@user}"} class="btn btn-primary">Done</.link>
        </div>
      </section>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <.header>
        {@page_title}
        <:subtitle>For {@user.name}</:subtitle>
      </.header>

      <.form for={@form} id="api-key-form" class="card" phx-change="validate" phx-submit="save">
        <.input
          field={@form[:name]}
          label="Name"
          placeholder="e.g. laptop coding agent"
          hint="What the key is for."
          required
        />
        <.inputs_for :let={policy} field={@form[:policy]}>
          <.input
            field={policy[:allowed_personas]}
            type="checkgroup"
            label="Allowed crew"
            options={@persona_options}
            hint="None checked means the user's whole crew, including personas added later."
          />
          <.input
            field={policy[:default_persona]}
            type="select"
            label="Default persona"
            prompt="The user's default persona"
            options={@persona_options}
            hint="Used when a client asks for a model that isn't a meridian/ persona."
          />
        </.inputs_for>
        <div class="form-actions">
          <.button phx-disable-with="Saving...">
            {if @live_action == :new, do: "Mint key", else: "Save"}
          </.button>
          <.link navigate={~p"/admin/users/#{@user}"}>Cancel</.link>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate", %{"api_key" => params}, socket) do
    changeset = Accounts.change_api_key(socket.assigns.api_key, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"api_key" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  defp save(socket, :new, params) do
    case Accounts.mint_api_key(socket.assigns.user, params) do
      {:ok, api_key} -> {:noreply, assign(socket, minted: api_key, page_title: "API key minted")}
      {:error, changeset} -> {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save(socket, :edit, params) do
    case Accounts.update_api_key(socket.assigns.api_key, params) do
      {:ok, _api_key} ->
        {:noreply,
         socket
         |> put_flash(:info, "API key updated.")
         |> push_navigate(to: ~p"/admin/users/#{socket.assigns.user}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
