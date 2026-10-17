defmodule MeridianWeb.Admin.UserLive.Form do
  use MeridianWeb, :live_view

  alias Meridian.{Accounts, Personas, Upstream}
  alias Meridian.Accounts.User
  alias Meridian.Personas.Persona

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(page_title: "New user", user: %User{}, force: false)
    |> assign(form: to_form(Accounts.change_user(%User{})))
    |> assign(persona_form: to_form(Personas.change_persona(%Persona{}), as: :persona))
    |> assign_upstream_models()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    user = Accounts.get_user!(id)

    socket
    |> assign(page_title: "Edit #{user.name}", user: user)
    |> assign(form: to_form(Accounts.change_user(user)))
  end

  defp assign_upstream_models(socket) do
    case connected?(socket) && Upstream.list_models() do
      {:ok, models} -> assign(socket, upstream_models: models, upstream_error: nil)
      {:error, reason} -> assign(socket, upstream_models: [], upstream_error: reason)
      false -> assign(socket, upstream_models: [], upstream_error: nil)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <.header>
        {@page_title}
        <:subtitle :if={@live_action == :new}>
          A default persona (<code>meridian/default</code>) is created along with the user.
        </:subtitle>
      </.header>

      <.form for={@form} id="user-form" class="card" phx-change="validate" phx-submit="save">
        <.input field={@form[:name]} label="Name" required />
        <.input field={@form[:email]} type="email" label="Email" required />

        <%= if @live_action == :new do %>
          <h2>Default persona</h2>
          <.input
            field={@persona_form[:model]}
            label="Upstream model"
            list="upstream-models"
            autocomplete="off"
            hint={model_hint(@upstream_error)}
            required
          />
          <.model_datalist id="upstream-models" models={@upstream_models} />
          <.input
            type="checkbox"
            name="force"
            id="force"
            value={@force}
            label="Skip upstream model validation"
            hint="For upstreams that don't list every model, or that are temporarily down."
          />
        <% end %>

        <div class="form-actions">
          <.button phx-disable-with="Saving...">Save</.button>
          <.link navigate={cancel_path(@user)}>Cancel</.link>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  defp model_hint(nil), do: "The model this persona sends requests to."
  defp model_hint(_error), do: "Couldn't list upstream models; check LLM_BASE_URL."

  defp cancel_path(%User{id: nil}), do: ~p"/admin/users"
  defp cancel_path(user), do: ~p"/admin/users/#{user}"

  @impl true
  def handle_event("validate", params, socket) do
    form =
      socket.assigns.user
      |> Accounts.change_user(params["user"] || %{})
      |> to_form(action: :validate)

    socket =
      if socket.assigns.live_action == :new do
        persona_form =
          %Persona{}
          |> Personas.change_persona(default_persona_attrs(params))
          |> to_form(as: :persona, action: :validate)

        assign(socket, persona_form: persona_form, force: params["force"] == "true")
      else
        socket
      end

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", params, socket), do: save(socket, socket.assigns.live_action, params)

  defp save(socket, :new, params) do
    force = params["force"] == "true"

    case Accounts.create_user(params["user"] || %{}, params["persona"] || %{}, force: force) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User created.")
         |> push_navigate(to: ~p"/admin/users/#{user}")}

      {:error, :user, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, :persona, changeset} ->
        {:noreply, assign(socket, persona_form: to_form(changeset, as: :persona), force: force)}
    end
  end

  defp save(socket, :edit, params) do
    case Accounts.update_user(socket.assigns.user, params["user"] || %{}) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User updated.")
         |> push_navigate(to: ~p"/admin/users/#{user}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  # Only the model is entered here; slug and name are filled in by Accounts.create_user/3.
  defp default_persona_attrs(params) do
    Map.merge(%{"slug" => "default", "name" => "Default"}, params["persona"] || %{})
  end
end
