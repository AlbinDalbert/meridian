defmodule Meridian.Skills.Skill do
  @moduledoc """
  A skill: instructions for a kind of task (`prompt`), which the model loads when a task
  matches its `description` (see `Meridian.Skills`). Global skills (`user_id` nil) can be used
  by everyone; a user's own skills only by that user.

  `recommended_extensions` lists the ids of extensions the skill works best with. It's a hint
  for whoever sets up an agent, not a requirement.
  """
  use Meridian.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "skills" do
    field :name, :string
    field :description, :string
    field :prompt, :string
    field :recommended_extensions, {:array, :binary_id}, default: []

    belongs_to :user, Meridian.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [:name, :description, :prompt, :recommended_extensions])
    |> update_change(:name, &trim/1)
    |> update_change(:description, &trim/1)
    |> validate_required([:name, :description, :prompt])
    |> validate_length(:name, max: 64)
    |> validate_length(:description, max: 1024)
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9_-]*$/,
      message: "must be lowercase letters, digits, '-' or '_'"
    )
    |> unique_constraint(:name, name: :skills_global_name_index)
    |> unique_constraint(:name, name: :skills_user_id_name_index)
  end

  # A field cleared in a form is cast to nil.
  defp trim(nil), do: nil
  defp trim(text), do: String.trim(text)

  @doc "Whether every user can use the skill."
  def global?(%__MODULE__{user_id: user_id}), do: is_nil(user_id)
end
