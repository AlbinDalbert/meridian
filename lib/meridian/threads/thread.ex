defmodule Meridian.Threads.Thread do
  @moduledoc """
  A conversation owned by a user. The server owns its history (`Meridian.Threads.Message`) and
  the runs that generate replies (`Meridian.Runs.Run`).

  `tags` are free-form labels for clients to use as they like (e.g. `"pinned"`); Meridian only
  stores them and filters by them. Blank tags are dropped (by `cast`) and the rest trimmed.
  """
  use Meridian.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @max_tags 50
  @max_tag_length 100

  schema "threads" do
    field :title, :string
    field :tags, {:array, :string}, default: []

    belongs_to :user, Meridian.Accounts.User
    belongs_to :agent, Meridian.Agents.Agent

    has_many :messages, Meridian.Threads.Message
    has_many :runs, Meridian.Runs.Run

    timestamps()
  end

  @doc false
  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [:title, :tags])
    |> update_change(:title, &String.trim/1)
    |> validate_length(:title, max: 500)
    |> update_change(:tags, fn tags ->
      tags |> List.wrap() |> Enum.map(&String.trim/1) |> Enum.uniq()
    end)
    |> validate_length(:tags, max: @max_tags)
    |> validate_change(:tags, fn :tags, tags ->
      if Enum.all?(tags, &(String.length(&1) <= @max_tag_length)),
        do: [],
        else: [tags: "must be at most #{@max_tag_length} characters each"]
    end)
  end
end
