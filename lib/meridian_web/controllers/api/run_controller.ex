defmodule MeridianWeb.Api.RunController do
  @moduledoc "`/api/runs/:id`: run status, and cancellation."
  use MeridianWeb, :controller

  alias Meridian.Runs

  action_fallback MeridianWeb.Api.FallbackController

  def show(conn, %{"id" => id}) do
    with %{} = run <- Runs.get_user_run(conn.assigns.current_user, id) do
      render(conn, :show, run: run)
    end
  end

  @doc """
  Cancels a run. A queued run is cancelled immediately; a running one is asked to stop and
  ends with a `run.cancelled` event shortly after, so the response may still say `running`.
  """
  def cancel(conn, %{"id" => id}) do
    with %{} = run <- Runs.get_user_run(conn.assigns.current_user, id),
         {:ok, run} <- Runs.cancel_run(run) do
      conn
      |> put_status(:accepted)
      |> render(:show, run: run)
    end
  end
end
