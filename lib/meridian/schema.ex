defmodule Meridian.Schema do
  @moduledoc """
  Shared defaults for Meridian's Ecto schemas: UUIDv7 primary keys and microsecond UTC
  timestamps.

  Ids are generated with monotonic precision, so ids created on one node sort in creation order
  even within the same millisecond (messages are ordered by id).

      use Meridian.Schema
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, Ecto.UUID, autogenerate: [version: 7, precision: :monotonic]}
      @foreign_key_type Ecto.UUID
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
