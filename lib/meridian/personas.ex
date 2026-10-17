defmodule Meridian.Personas do
  @moduledoc """
  Personas: named bundles of system prompt, upstream model, and default params that clients
  pick as a model (`meridian/<slug>`). Every persona belongs to a user, and each user has
  exactly one default persona.
  """
  import Ecto.Query

  alias Ecto.Changeset
  alias Meridian.Accounts.ApiKey.Policy
  alias Meridian.Accounts.User
  alias Meridian.Personas.Persona
  alias Meridian.Repo
  alias Meridian.Upstream

  def list_personas(%User{id: user_id}) do
    Repo.all(
      from p in Persona,
        where: p.user_id == ^user_id,
        order_by: [desc: p.is_default, asc: p.slug]
    )
  end

  def get_persona!(id), do: Repo.get!(Persona, id)

  @doc "Gets persona `id` if it belongs to `user`; raises `Ecto.NoResultsError` otherwise."
  def get_persona!(%User{id: user_id}, id), do: Repo.get_by!(Persona, id: id, user_id: user_id)

  def get_persona_by_slug(%User{id: user_id}, slug) do
    Repo.get_by(Persona, user_id: user_id, slug: slug)
  end

  def get_default_persona(%User{id: user_id}) do
    Repo.get_by(Persona, user_id: user_id, is_default: true)
  end

  @doc """
  Resolves the persona a key uses: the persona with `slug`, or with no slug the policy's
  `default_persona`, falling back to the user's default persona. Personas the policy doesn't
  allow are treated as not found.
  """
  @spec resolve_persona(User.t(), Policy.t(), String.t() | nil) ::
          {:ok, Persona.t()} | {:error, :persona_not_found}
  def resolve_persona(%User{} = user, %Policy{} = policy, slug) do
    persona =
      case {slug, policy.default_persona} do
        {nil, nil} -> get_default_persona(user)
        {nil, default} -> get_persona_by_slug(user, default)
        {slug, _default} -> get_persona_by_slug(user, slug)
      end

    if persona && Policy.allows?(policy, persona.slug),
      do: {:ok, persona},
      else: {:error, :persona_not_found}
  end

  @doc """
  Applies a persona to a chat completions request body: the persona's params are defaults the
  body can override, the model is replaced with the persona's upstream model, and the persona's
  system prompt goes before the body's (merged into its leading system message, if there is
  one, since some chat templates only accept a single system message).
  """
  @spec apply_to_request(Persona.t(), map()) :: map()
  def apply_to_request(%Persona{} = persona, body) do
    persona.params
    |> Map.merge(body)
    |> Map.put("model", persona.model)
    |> Map.update("messages", [], &put_system_prompt(&1, persona.system_prompt))
  end

  defp put_system_prompt(messages, prompt) when prompt in [nil, ""], do: messages

  defp put_system_prompt([%{"role" => role, "content" => content} = first | rest], prompt)
       when role in ["system", "developer"] do
    case content do
      text when is_binary(text) ->
        [%{first | "content" => prompt <> "\n\n" <> text} | rest]

      parts when is_list(parts) ->
        [%{first | "content" => [%{"type" => "text", "text" => prompt} | parts]} | rest]

      _ ->
        [%{"role" => "system", "content" => prompt}, first | rest]
    end
  end

  defp put_system_prompt(messages, prompt) when is_list(messages) do
    [%{"role" => "system", "content" => prompt} | messages]
  end

  # Not a valid message list; leave it for the upstream to reject.
  defp put_system_prompt(messages, _prompt), do: messages

  def change_persona(%Persona{} = persona, attrs \\ %{}), do: Persona.changeset(persona, attrs)

  @doc """
  Creates a persona for `user`.

  The upstream model is validated against the upstream's model list unless `force: true` is
  given (for upstreams that don't list every model, or that are temporarily down).
  """
  def create_persona(%User{} = user, attrs, opts \\ []) do
    %Persona{user_id: user.id}
    |> Persona.changeset(attrs)
    |> validate_model(opts)
    |> Repo.insert()
  end

  @doc "Updates a persona. Takes the same options as `create_persona/3`."
  def update_persona(%Persona{} = persona, attrs, opts \\ []) do
    persona
    |> Persona.changeset(attrs)
    |> validate_model(opts)
    |> Repo.update()
  end

  @doc "Deletes a persona. The default persona can't be deleted."
  def delete_persona(%Persona{is_default: true}), do: {:error, :default_persona}
  def delete_persona(%Persona{} = persona), do: Repo.delete(persona)

  @doc "Makes `persona` its user's default persona."
  def make_default(%Persona{is_default: true} = persona), do: {:ok, persona}

  def make_default(%Persona{} = persona) do
    Repo.transact(fn ->
      Repo.update_all(
        from(p in Persona, where: p.user_id == ^persona.user_id and p.is_default),
        set: [is_default: false]
      )

      persona |> Changeset.change(is_default: true) |> Repo.update()
    end)
  end

  @doc """
  Checks that a changed `:model` is offered by the upstream, unless `opts[:force]` is true.
  """
  def validate_model(%Changeset{} = changeset, opts) do
    model = Changeset.get_change(changeset, :model)

    if is_nil(model) or Keyword.get(opts, :force, false) or not changeset.valid? do
      changeset
    else
      case Upstream.model_available?(model) do
        {:ok, true} ->
          changeset

        {:ok, false} ->
          Changeset.add_error(changeset, :model, "is not offered by the upstream")

        {:error, :not_configured} ->
          Changeset.add_error(changeset, :model, "can't be validated: no upstream is configured")

        {:error, _reason} ->
          Changeset.add_error(changeset, :model, "can't be validated: upstream unreachable")
      end
    end
  end
end
