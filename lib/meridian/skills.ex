defmodule Meridian.Skills do
  @moduledoc """
  Skills: instructions for a kind of task, which the model loads when it needs them.

  A skill is a row: a name, a description, and a prompt. Global skills (made in the admin
  console) can be used by everyone; a user's own skills (made in `/me`) only by that user.
  Personas enable skills by id (`personas.skills`); ids of skills that are gone, or that the
  persona's user can't use, are kept but ignored.

  In a run, the enabled skills reach the model in two parts (progressive disclosure): an index
  in the system prompt (each skill's name and description, `prompt_section/1`), and a
  `load_skill` tool (`tool/1`) that returns a skill's prompt. So a skill only costs its
  description until the model decides it needs the rest.

  A skill can recommend extensions it works best with (`recommended_extensions`). That's only a
  hint, shown when a persona has the skill without them (`missing_extensions/2`); nothing
  depends on it.
  """
  import Ecto.Query

  alias Meridian.Accounts.User
  alias Meridian.Personas.Persona
  alias Meridian.Repo
  alias Meridian.Skills.Skill

  @tool_name "load_skill"

  @doc "Every skill, global ones first, with its user."
  def list_skills do
    Repo.all(
      from s in Skill,
        left_join: u in assoc(s, :user),
        order_by: [asc_nulls_first: s.user_id, asc: u.name, asc: s.name],
        preload: [user: u]
    )
  end

  @doc "The skills `user` can use: the global ones and their own, by name."
  def list_available(%User{id: user_id}) do
    Repo.all(from s in available(user_id), order_by: [asc: s.name, asc_nulls_first: s.user_id])
  end

  defp available(nil), do: from(s in Skill, where: is_nil(s.user_id))

  defp available(user_id),
    do: from(s in Skill, where: is_nil(s.user_id) or s.user_id == ^user_id)

  def get_skill!(id), do: Skill |> Repo.get!(id) |> Repo.preload(:user)

  @doc """
  Gets skill `id` if `user` can use it (it's global or theirs); raises `Ecto.NoResultsError`
  otherwise.
  """
  def get_available_skill!(%User{id: user_id}, id),
    do: Repo.one!(from s in available(user_id), where: s.id == ^id)

  def change_skill(%Skill{} = skill, attrs \\ %{}), do: Skill.changeset(skill, attrs)

  @doc "Creates a skill: global with no `owner`, otherwise the owner's own."
  def create_skill(owner, attrs) do
    %Skill{user_id: owner && owner.id}
    |> Skill.changeset(attrs)
    |> Repo.insert()
  end

  def update_skill(%Skill{} = skill, attrs), do: skill |> Skill.changeset(attrs) |> Repo.update()

  def delete_skill(%Skill{} = skill), do: Repo.delete(skill)

  ## Personas

  @doc """
  The skills `persona` enables that its user can use, by name. If a user's own skill has the
  same name as a global one, the user's own wins.
  """
  @spec enabled(Persona.t()) :: [Skill.t()]
  def enabled(%Persona{skills: [_ | _] = ids, user_id: user_id}) do
    ids = Enum.filter(ids, &match?({:ok, _}, Ecto.UUID.cast(&1)))

    from(s in available(user_id), where: s.id in ^ids, order_by: [asc: s.name])
    |> Repo.all()
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {_name, skills} -> Enum.find(skills, List.first(skills), & &1.user_id) end)
    |> Enum.sort_by(& &1.name)
  end

  def enabled(_persona), do: []

  @doc """
  The extensions `skill` recommends that aren't among `enabled_extension_ids`, as
  `%{id, name}` (name nil for extensions that are gone or that `user` can't use).
  """
  def missing_extensions(%Skill{} = skill, enabled_extension_ids, %User{} = user) do
    case skill.recommended_extensions -- enabled_extension_ids do
      [] ->
        []

      missing ->
        names =
          user
          |> Meridian.Extensions.list_available()
          |> Map.new(&{&1.id, &1.name})

        Enum.map(missing, &%{id: &1, name: names[&1]})
    end
  end

  ## Runs

  @doc "The system prompt section listing `skills`, or nil if there are none."
  @spec prompt_section([Skill.t()]) :: String.t() | nil
  def prompt_section([]), do: nil

  def prompt_section(skills) do
    index = Enum.map_join(skills, "\n", &"- #{&1.name}: #{&1.description}")

    """
    You have skills: instructions for particular kinds of tasks. When a task matches a \
    skill's description, call the #{@tool_name} tool with its name and follow the \
    instructions it returns before you answer.

    #{index}\
    """
  end

  @doc """
  The `load_skill` tool for `skills`, in the shape of a run's tools (see
  `Meridian.Extensions.tool_set/1`), or nil if there are none. Its `skills` are what it loads
  from, by name: the run uses the skills as they were when it started.
  """
  def tool([]), do: nil

  def tool(skills) do
    %{
      name: @tool_name,
      skills: Map.new(skills, &{&1.name, &1}),
      definition: %{
        "name" => @tool_name,
        "description" => "Loads a skill: instructions for a kind of task.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "enum" => Enum.map(skills, & &1.name),
              "description" => "The skill's name."
            }
          },
          "required" => ["name"]
        }
      }
    }
  end

  @doc "Runs the `load_skill` tool: the prompt of the skill named in `arguments`."
  @spec load(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def load(%{skills: skills}, arguments) do
    case Map.fetch(skills, arguments["name"]) do
      {:ok, skill} -> {:ok, skill.prompt}
      :error -> {:error, "there is no skill named #{inspect(arguments["name"])}."}
    end
  end
end
