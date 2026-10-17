defmodule MeridianWeb.Api.RunJSON do
  alias Meridian.Accounts.{ApiKey, User}
  alias Meridian.Runs.Run
  alias MeridianWeb.EventsToken

  def show(%{run: run} = assigns), do: %{data: data(run, credential(assigns))}

  @doc """
  A run as clients see it. `events_token` lets a browser's `EventSource` (which can't send an
  `Authorization` header) read this run's events: `GET /api/runs/:id/events?token=...`.
  `credential` is the API key, or the user for clients signed in through the OIDC provider.
  """
  def data(%Run{} = run, %struct{} = credential) when struct in [ApiKey, User] do
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
      events_token: EventsToken.sign(run, credential)
    }
  end

  @doc "What a request authenticated with: its API key, or its user for OIDC access tokens."
  def credential(%{current_api_key: nil, current_user: user}), do: user
  def credential(%{current_api_key: api_key}), do: api_key
end
