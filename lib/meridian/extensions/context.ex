defmodule Meridian.Extensions.Context do
  @moduledoc """
  Where an extension's hook is called: whose run or thread it is, the persona (as frozen into
  the run, for run hooks), and this extension's settings for that persona (merged over its
  defaults). Scripts get it as their last argument (see `to_lua/1`), and it decides whose data
  their `meridian.*` functions can reach.

  `run_id` is nil for thread hooks.
  """

  alias Meridian.Personas.Persona

  @type t :: %__MODULE__{
          run_id: Ecto.UUID.t() | nil,
          thread_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          persona: Persona.t(),
          settings: map()
        }

  @enforce_keys [:persona]
  defstruct [:run_id, :thread_id, :user_id, :persona, settings: %{}]

  @doc "The context of a run's hooks, with the persona frozen into the run."
  def for_run(%Meridian.Runs.Run{} = run) do
    persona = Persona.from_snapshot(run.persona_snapshot)

    %__MODULE__{
      run_id: run.id,
      thread_id: run.thread_id,
      user_id: persona.user_id,
      persona: persona
    }
  end

  @doc "The context of a thread's hooks."
  def for_thread(%Meridian.Threads.Thread{} = thread, %Persona{} = persona) do
    %__MODULE__{thread_id: thread.id, user_id: thread.user_id, persona: persona}
  end

  @doc "The context as scripts see it: a plain map."
  def to_lua(%__MODULE__{} = ctx) do
    %{
      "run_id" => ctx.run_id,
      "thread_id" => ctx.thread_id,
      "user_id" => ctx.user_id,
      "settings" => ctx.settings,
      "persona" => %{
        "id" => ctx.persona.id,
        "slug" => ctx.persona.slug,
        "name" => ctx.persona.name,
        "model" => ctx.persona.model
      }
    }
  end

  @doc "The context, stored in a background job's args (see `Meridian.Extensions.Job`)."
  def to_job(%__MODULE__{} = ctx) do
    %{
      "run_id" => ctx.run_id,
      "thread_id" => ctx.thread_id,
      "user_id" => ctx.user_id,
      "settings" => ctx.settings,
      "persona" => Persona.snapshot(ctx.persona)
    }
  end

  @doc "Rebuilds a context from `to_job/1`."
  def from_job(%{} = args) do
    %__MODULE__{
      run_id: args["run_id"],
      thread_id: args["thread_id"],
      user_id: args["user_id"],
      settings: args["settings"] || %{},
      persona: Persona.from_snapshot(args["persona"] || %{})
    }
  end
end
