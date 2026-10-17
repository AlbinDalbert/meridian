defmodule Meridian.Extensions.Context do
  @moduledoc """
  Where an extension's hook is called: whose run or thread it is, the agent (as frozen into
  the run, for run hooks), and this extension's settings for that agent (merged over its
  defaults). Scripts get it as their last argument (see `to_lua/1`), and it decides whose data
  their `meridian.*` functions can reach.

  `run_id` is nil for thread hooks.
  """

  alias Meridian.Agents.Agent

  @type t :: %__MODULE__{
          run_id: Ecto.UUID.t() | nil,
          thread_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          agent: Agent.t(),
          settings: map()
        }

  @enforce_keys [:agent]
  defstruct [:run_id, :thread_id, :user_id, :agent, settings: %{}]

  @doc "The context of a run's hooks, with the agent frozen into the run."
  def for_run(%Meridian.Runs.Run{} = run) do
    agent = Agent.from_snapshot(run.agent_snapshot)

    %__MODULE__{
      run_id: run.id,
      thread_id: run.thread_id,
      user_id: agent.user_id,
      agent: agent
    }
  end

  @doc "The context of a thread's hooks."
  def for_thread(%Meridian.Threads.Thread{} = thread, %Agent{} = agent) do
    %__MODULE__{thread_id: thread.id, user_id: thread.user_id, agent: agent}
  end

  @doc "The context as scripts see it: a plain map."
  def to_lua(%__MODULE__{} = ctx) do
    %{
      "run_id" => ctx.run_id,
      "thread_id" => ctx.thread_id,
      "user_id" => ctx.user_id,
      "settings" => ctx.settings,
      "agent" => %{
        "id" => ctx.agent.id,
        "slug" => ctx.agent.slug,
        "name" => ctx.agent.name,
        "model" => ctx.agent.model
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
      "agent" => Agent.snapshot(ctx.agent)
    }
  end

  @doc "Rebuilds a context from `to_job/1`."
  def from_job(%{} = args) do
    %__MODULE__{
      run_id: args["run_id"],
      thread_id: args["thread_id"],
      user_id: args["user_id"],
      settings: args["settings"] || %{},
      agent: Agent.from_snapshot(args["agent"] || %{})
    }
  end
end
