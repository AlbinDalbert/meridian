defmodule Meridian.Threads.Thread do
  @moduledoc """
  A conversation owned by a user. The server owns its history (`Meridian.Threads.Message`) and
  the runs that generate replies (`Meridian.Runs.Run`).
  """
  use Meridian.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "threads" do
    field :title, :string

    belongs_to :user, Meridian.Accounts.User
    belongs_to :persona, Meridian.Personas.Persona

    has_many :messages, Meridian.Threads.Message
    has_many :runs, Meridian.Runs.Run

    timestamps()
  end

  @doc false
  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [:title])
    |> update_change(:title, &String.trim/1)
    |> validate_length(:title, max: 500)
  end
end
