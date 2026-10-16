defmodule Meridian.Schema do
  @moduledoc """
  Shared defaults for Meridian's Ecto schemas: UUIDv7 primary keys (time-ordered) and
  microsecond UTC timestamps.

      use Meridian.Schema
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}
      @foreign_key_type Ecto.UUID
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
