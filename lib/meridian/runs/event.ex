defmodule Meridian.Runs.Event do
  @moduledoc """
  An entry in a run's event log. `seq` increases by one per event within a run, so a client
  that has seen up to `seq` can resume from there.

  Core types: `run.started`, `run.completed`, `run.failed`, `run.cancelled`, `message.delta`
  (coalesced text and reasoning deltas), and `message.completed`.
  """
  use Ecto.Schema

  @primary_key false
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @terminal_types ~w(run.completed run.failed run.cancelled)

  schema "run_events" do
    belongs_to :run, Meridian.Runs.Run, primary_key: true
    field :seq, :integer, primary_key: true
    field :type, :string
    field :payload, :map, default: %{}

    timestamps()
  end

  @doc "Whether this event ends its run's stream."
  def terminal?(%__MODULE__{type: type}), do: type in @terminal_types

  @doc "The event as clients see it (SSE `data`, admin UI)."
  def to_map(%__MODULE__{} = event) do
    %{
      run_id: event.run_id,
      seq: event.seq,
      type: event.type,
      payload: event.payload,
      inserted_at: event.inserted_at
    }
  end
end
