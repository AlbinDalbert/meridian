defmodule Meridian.Extensions.Extension do
  @moduledoc """
  An extension: a named Lua script (see `Meridian.Extensions.Script`). Global extensions
  (`user_id` nil) can be used by everyone; a user's own extensions only by that user.

  Personas enable extensions by id, so names only need to be unique among the global
  extensions and among each user's own.
  """
  use Meridian.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "extensions" do
    field :name, :string
    field :source, :string, default: ""

    belongs_to :user, Meridian.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(extension, attrs) do
    extension
    |> cast(attrs, [:name, :source], empty_values: [nil])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 64)
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9_-]*$/,
      message: "must be lowercase letters, digits, '-' or '_'"
    )
    |> unique_constraint(:name, name: :extensions_global_name_index)
    |> unique_constraint(:name, name: :extensions_user_id_name_index)
  end

  @doc "Whether every user can use the extension."
  def global?(%__MODULE__{user_id: user_id}), do: is_nil(user_id)
end
