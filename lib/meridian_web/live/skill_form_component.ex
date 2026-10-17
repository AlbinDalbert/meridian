defmodule MeridianWeb.SkillFormComponent do
  @moduledoc """
  The skill form, shared by the admin console and `/me`: name, description, prompt, the
  extensions it recommends, saving, and deleting. The LiveView that renders it loads the skill
  (making sure the person may edit it) and passes:

    * `skill` - the skill to edit, or a new `%Skill{}` (with `user_id` set for a user's own).
    * `owner` - who the skill belongs to (nil for a global one): it can recommend the
      extensions they can use.
    * `return_to` - where to go after deleting.
    * `saved_path` - a function from the saved skill to where to go after saving.
  """
  use MeridianWeb, :live_component

  alias Meridian.Accounts.User
  alias Meridian.{Extensions, Skills}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if socket.assigns[:form] do
        socket
      else
        # A global skill can only count on global extensions.
        extensions = Extensions.list_available(socket.assigns.owner || %User{})

        socket
        |> assign(form: to_form(Skills.change_skill(socket.assigns.skill)))
        |> assign(extension_options: Enum.map(extensions, &{&1.name, &1.id}))
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.form
        for={@form}
        id="skill-form"
        class="card"
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
      >
        <.input
          field={@form[:name]}
          label="Name"
          hint="Lowercase letters, digits, '-' and '_'. The model loads the skill by this name."
          required
        />
        <.input
          field={@form[:description]}
          label="Description"
          hint="What it's for, and when to use it. The model reads this to decide whether to load the skill."
          required
        />
        <.input
          field={@form[:prompt]}
          type="textarea"
          label="Instructions"
          rows="16"
          hint="What the model gets when it loads the skill."
          required
        />
        <.input
          :if={@extension_options != []}
          field={@form[:recommended_extensions]}
          type="checkgroup"
          label="Works best with"
          options={@extension_options}
          hint="Extensions the skill relies on. A persona with the skill but without one of these gets a warning; nothing stops it."
        />
        <div class="form-actions">
          <.button phx-disable-with="Saving...">Save</.button>
          <.link navigate={@return_to}>Cancel</.link>
          <button
            :if={@skill.id}
            type="button"
            class="link danger push-right"
            phx-click="delete"
            phx-target={@myself}
            data-confirm={"Delete #{@skill.name}? Personas that use it stop getting it."}
          >
            Delete
          </button>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"skill" => params}, socket) do
    changeset = Skills.change_skill(socket.assigns.skill, normalize(params))
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"skill" => params}, socket) do
    skill = socket.assigns.skill
    params = normalize(params)

    result =
      if skill.id,
        do: Skills.update_skill(skill, params),
        else: Skills.create_skill(socket.assigns.owner, params)

    case result do
      {:ok, skill} ->
        {:noreply,
         socket
         |> put_flash(:info, "Skill saved.")
         |> push_navigate(to: socket.assigns.saved_path.(skill))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("delete", _params, socket) do
    {:ok, _skill} = Skills.delete_skill(socket.assigns.skill)

    {:noreply,
     socket
     |> put_flash(:info, "Skill deleted.")
     |> push_navigate(to: socket.assigns.return_to)}
  end

  # The checkgroup sends "" so that unchecking everything still submits a list.
  defp normalize(%{"recommended_extensions" => ids} = params) when is_list(ids),
    do: %{params | "recommended_extensions" => Enum.reject(ids, &(&1 == ""))}

  defp normalize(params), do: params
end
