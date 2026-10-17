defmodule Meridian.Accounts.ApiKey.Policy do
  @moduledoc """
  What an API key may do, stored as JSON on the key.

    * `default_agent` - slug of the agent used when a client asks for a model that isn't a
      Meridian agent. Falls back to the user's default agent when unset.
    * `allowed_agents` - slugs the key may use. Empty means all of the user's agents.
    * `extensions` - per-extension overrides for the native surface (unused until extensions
      exist).
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field :default_agent, :string
    field :allowed_agents, {:array, :string}, default: []
    field :extensions, :map, default: %{}
  end

  @doc false
  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [:default_agent, :allowed_agents])
    |> update_change(:allowed_agents, fn slugs -> Enum.reject(slugs, &(&1 in [nil, ""])) end)
    |> validate_default_allowed()
  end

  defp validate_default_allowed(changeset) do
    default = get_field(changeset, :default_agent)
    allowed = get_field(changeset, :allowed_agents)

    if default && allowed != [] && default not in allowed do
      add_error(changeset, :default_agent, "must be one of the allowed agents")
    else
      changeset
    end
  end

  @doc "Whether the policy allows using the agent with the given slug."
  def allows?(%__MODULE__{allowed_agents: []}, _slug), do: true
  def allows?(%__MODULE__{allowed_agents: allowed}, slug), do: slug in allowed
end
