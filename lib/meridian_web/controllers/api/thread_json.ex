defmodule MeridianWeb.Api.ThreadJSON do
  alias Meridian.Agents.Agent
  alias Meridian.Threads.Thread
  alias MeridianWeb.Api.RunJSON

  def index(%{threads: threads}), do: %{data: Enum.map(threads, &data/1)}

  def show(%{thread: thread} = assigns) do
    active_run = if run = assigns[:active_run], do: RunJSON.data(run, RunJSON.credential(assigns))
    %{data: Map.put(data(thread), :active_run, active_run)}
  end

  def data(%Thread{} = thread) do
    %{
      id: thread.id,
      title: thread.title,
      tags: thread.tags,
      agent: thread.agent && Agent.model_id(thread.agent),
      inserted_at: thread.inserted_at,
      updated_at: thread.updated_at
    }
  end
end
