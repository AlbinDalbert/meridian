defmodule Meridian.Accounts.ApiKey.Policy do
  @moduledoc """
  What an API key may do, stored as JSON on the key.

    * `default_persona` - slug of the persona used when a client asks for a model that isn't a
      Meridian persona. Falls back to the user's default persona when unset.
    * `allowed_personas` - slugs the key may use. Empty means all of the user's personas.
    * `extensions` - per-extension overrides for the native surface (unused until extensions
      exist).
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :default_persona, :string
    field :allowed_personas, {:array, :string}, default: []
    field :extensions, :map, default: %{}
  end

  @doc false
  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [:default_persona, :allowed_personas])
    |> update_change(:allowed_personas, fn slugs -> Enum.reject(slugs, &(&1 in [nil, ""])) end)
    |> validate_default_allowed()
  end

  defp validate_default_allowed(changeset) do
    default = get_field(changeset, :default_persona)
    allowed = get_field(changeset, :allowed_personas)

    if default && allowed != [] && default not in allowed do
      add_error(changeset, :default_persona, "must be one of the allowed personas")
    else
      changeset
    end
  end

  @doc "Whether the policy allows using the persona with the given slug."
  def allows?(%__MODULE__{allowed_personas: []}, _slug), do: true
  def allows?(%__MODULE__{allowed_personas: allowed}, slug), do: slug in allowed
end
