defmodule Meridian.Runs.Run do
  @moduledoc """
  One agent turn: from a user message to the final assistant message.

  A run is `queued` when created, `running` once a `Meridian.Runs.RunServer` picks it up, and
  ends `completed`, `failed`, or `cancelled`. `awaiting_approval` is reserved for tool approval.
  A thread has at most one active (`queued`, `running`, `awaiting_approval`) run.

  `agent_snapshot` freezes the agent the run was started with, so editing an agent never
  changes a run in flight.
  """
  use Meridian.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses [:queued, :running, :awaiting_approval, :completed, :failed, :cancelled]
  @active_statuses [:queued, :running, :awaiting_approval]

  schema "runs" do
    field :status, Ecto.Enum, values: @statuses, default: :queued
    field :agent_snapshot, :map
    field :model, :string
    field :usage, :map
    field :error, :map
    field :heartbeat_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :thread, Meridian.Threads.Thread
    belongs_to :user_message, Meridian.Threads.Message

    timestamps()
  end

  @doc "Statuses in which a run still occupies its thread."
  def active_statuses, do: @active_statuses

  @doc "Whether the run has finished (completed, failed, or cancelled)."
  def finished?(%__MODULE__{status: status}), do: status not in @active_statuses

  @doc false
  def create_changeset(run, attrs) do
    run
    |> change(attrs)
    |> validate_required([:thread_id, :user_message_id, :agent_snapshot, :model])
    |> unique_constraint(:thread_id, name: :runs_one_active_per_thread_index)
  end
end
