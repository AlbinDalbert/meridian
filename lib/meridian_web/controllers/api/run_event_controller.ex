defmodule MeridianWeb.Api.RunEventController do
  @moduledoc """
  `GET /api/runs/:id/events`: a run's events as server-sent events.

  Replays the persisted events after the client's cursor (`Last-Event-ID` header or `?after=`
  query param, default 0), then streams live events until the run ends. Each SSE event's `id`
  is the event's `seq`, so a reconnecting client (or `EventSource`) resumes without gaps or
  duplicates. Subscribing before replaying, and dropping live events already replayed,
  guarantees that.
  """
  use MeridianWeb, :controller

  alias Meridian.Runs
  alias Meridian.Runs.Event

  action_fallback MeridianWeb.Api.FallbackController

  @keepalive_interval :timer.seconds(15)

  def index(conn, %{"id" => id} = params) do
    with %{} = run <- Runs.get_user_run(conn.assigns.current_user, id),
         {:ok, after_seq} <- cursor(conn, params) do
      :ok = Runs.subscribe(run)

      conn =
        conn
        |> put_resp_content_type("text/event-stream", nil)
        |> put_resp_header("cache-control", "no-cache")
        # Ask reverse proxies (nginx) not to buffer the stream.
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)

      run
      |> Runs.list_events(after_seq)
      |> Enum.reduce_while({:cont, conn, after_seq}, fn event, {:cont, conn, _seq} ->
        case send_event(conn, event) do
          {:cont, conn} -> {:cont, {:cont, conn, event.seq}}
          halt -> {:halt, halt}
        end
      end)
      |> case do
        {:cont, conn, last_seq} -> stream_live(conn, last_seq)
        {:halt, conn} -> conn
      end
    end
  end

  defp stream_live(conn, last_seq) do
    receive do
      {:run_event, %Event{seq: seq}} when seq <= last_seq ->
        stream_live(conn, last_seq)

      {:run_event, %Event{} = event} ->
        case send_event(conn, event) do
          {:cont, conn} -> stream_live(conn, event.seq)
          {:halt, conn} -> conn
        end
    after
      @keepalive_interval ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_live(conn, last_seq)
          {:error, _reason} -> conn
        end
    end
  end

  # Sends one event. Halts after the run's terminal event, or if the client has gone away.
  defp send_event(conn, %Event{} = event) do
    data = Jason.encode_to_iodata!(Event.to_map(event))

    case chunk(conn, [
           "id: ",
           Integer.to_string(event.seq),
           "\nevent: ",
           event.type,
           "\ndata: ",
           data,
           "\n\n"
         ]) do
      {:ok, conn} -> if Event.terminal?(event), do: {:halt, conn}, else: {:cont, conn}
      {:error, _reason} -> {:halt, conn}
    end
  end

  defp cursor(conn, params) do
    value =
      case get_req_header(conn, "last-event-id") do
        [id | _] -> id
        [] -> Map.get(params, "after", "0")
      end

    case Integer.parse(value) do
      {seq, ""} when seq >= 0 -> {:ok, seq}
      _ -> {:error, :invalid_cursor}
    end
  end
end
