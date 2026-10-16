defmodule MeridianWeb.Api.RunJSON do
  alias Meridian.Accounts.ApiKey
  alias Meridian.Runs.Run
  alias MeridianWeb.EventsToken

  def show(%{run: run, current_api_key: api_key}), do: %{data: data(run, api_key)}

  @doc """
  A run as clients see it. `events_token` lets a browser's `EventSource` (which can't send an
  `Authorization` header) read this run's events: `GET /api/runs/:id/events?token=...`.
  """
  def data(%Run{} = run, %ApiKey{} = api_key) do
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
      finished_at: run.finished_at,
      events_token: EventsToken.sign(run, api_key)
    }
  end
end
