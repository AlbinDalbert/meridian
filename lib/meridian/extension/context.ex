defmodule Meridian.Extension.Context do
  @moduledoc """
  What an extension's hook handler knows about where it is called: whose run or thread it is,
  the persona (as frozen into the run, for run hooks), and this extension's settings for that
  persona (merged over its defaults).

  `run_id` is nil for thread hooks.
  """

  @type t :: %__MODULE__{
          run_id: Ecto.UUID.t() | nil,
          thread_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          persona: Meridian.Personas.Persona.t(),
          settings: map()
        }

  alias Meridian.Personas.Persona

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
end
