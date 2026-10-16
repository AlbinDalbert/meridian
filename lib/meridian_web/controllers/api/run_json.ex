defmodule MeridianWeb.Api.RunJSON do
  alias Meridian.Runs.Run

  def show(%{run: run}), do: %{data: data(run)}

  def data(%Run{} = run) do
    %{
      id: run.id,
      thread_id: run.thread_id,
      user_message_id: run.user_message_id,
      status: run.status,
      persona: "meridian/" <> run.persona_snapshot["slug"],
      model: run.model,
      usage: run.usage,
      error: run.error,
      inserted_at: run.inserted_at,
      started_at: run.started_at,
      finished_at: run.finished_at
    }
  end
end
