defmodule Meridian.Accounts.User do
  @moduledoc """
  A Meridian user. Users are created by the operator; there is no signup or user login.
  Clients identify a user with one of the user's API keys.
  """
  use Meridian.Schema

  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :email, :string

    has_many :api_keys, Meridian.Accounts.ApiKey
    has_many :personas, Meridian.Personas.Persona

    timestamps()
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email])
    |> update_change(:name, &String.trim/1)
    |> update_change(:email, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 200)
    |> validate_format(:email, ~r/^[^@\s]+@[^@\s]+$/, message: "must be a valid email address")
    |> unique_constraint(:email, name: :users_email_index)
  end
end
