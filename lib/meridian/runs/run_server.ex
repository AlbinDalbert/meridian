defmodule Meridian.Runs.RunServer do
  @moduledoc """
  Executes one run. Started by `Meridian.Runs.Worker` under `Meridian.Runs.Supervisor` and
  registered in `Meridian.Runs.Registry` by run id.

  The run is a single model call for now: build the context from the thread's history, apply
  the persona snapshot, stream the completion from the upstream, and save the reply. The
  upstream response is streamed into this process's mailbox (`into: :self`), so cancel
  requests, timers, and response chunks are all just messages.

  Text and reasoning deltas are buffered and emitted as one `message.delta` event per
  `:delta_flush_interval` (milliseconds; `0` emits one event per upstream chunk), so the event
  log stays small and live clients and replaying clients see exactly the same events.
  """
  use GenServer, restart: :temporary

  require Logger

  alias Meridian.{Personas, Runs, Threads, Upstream}
  alias Meridian.Personas.Persona
  alias Meridian.Runs.Run
  alias Meridian.Threads.Message
  alias Meridian.Upstream.SSE

  @registry Meridian.Runs.Registry
  @supervisor Meridian.Runs.Supervisor

  @doc "Starts the RunServer for `run_id` under the run supervisor."
  def start(run_id) do
    # Like a Task, remember who started us, so ownership-based test sandboxes (Ecto, Req.Test)
    # follow the run into this process.
    callers = [self() | Process.get(:"$callers", [])]
    DynamicSupervisor.start_child(@supervisor, {__MODULE__, {run_id, callers}})
  end

  def start_link({run_id, callers}) do
    GenServer.start_link(__MODULE__, {run_id, callers}, name: via(run_id))
  end

  @doc "The pid of the run's RunServer on this node, or nil."
  def whereis(run_id) do
    case Registry.lookup(@registry, run_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp via(run_id), do: {:via, Registry, {@registry, run_id}}

  ## Server

  @impl true
  def init({run_id, callers}) do
    Process.put(:"$callers", callers)
    # Trap exits so terminate/2 runs on shutdown and can fail the run instead of leaving it
    # "running" until the janitor notices.
    Process.flag(:trap_exit, true)
    Logger.metadata(run_id: run_id)

    state = %{
      run_id: run_id,
      run: nil,
      seq: 0,
      resp: nil,
      sse: SSE.new(),
      # Everything received so far, and what hasn't been emitted as a delta yet (iodata).
      text: [],
      reasoning: [],
      pending_text: [],
      pending_reasoning: [],
      finish_reason: nil,
      usage: nil,
      flush_timer: nil,
      idle_timer: nil
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    # Subscribe before taking the run, so a cancel sent as soon as it's running isn't missed.
    Runs.subscribe_control(state.run_id)

    case Runs.start_run(state.run_id) do
      {:ok, run, started} ->
        :timer.send_interval(config(:heartbeat_interval, :timer.seconds(10)), :heartbeat)
        request(%{state | run: run, seq: started.seq})

      {:error, :not_queued} ->
        # Cancelled before it started, or already handled.
        {:stop, :normal, state}
    end
  end

  defp request(state) do
    case Upstream.chat_completions(request_body(state.run)) do
      {:ok, %Req.Response{status: 200} = resp} ->
        {:noreply, reset_idle_timer(%{state | resp: resp})}

      {:ok, %Req.Response{} = resp} ->
        body = resp.body |> Enum.join() |> String.slice(0, 2000)
        Logger.warning("Upstream responded #{resp.status}: #{body}")

        fail(state, %{
          "code" => "upstream_error",
          "message" => upstream_error_message(body, resp.status),
          "status" => resp.status
        })

      {:error, :not_configured} ->
        fail(state, %{
          "code" => "upstream_not_configured",
          "message" => "No upstream is configured."
        })

      {:error, reason} ->
        Logger.warning("Upstream request failed: #{inspect(reason)}")

        fail(state, %{
          "code" => "upstream_unavailable",
          "message" => "The upstream is unavailable."
        })
    end
  end

  defp request_body(%Run{} = run) do
    messages =
      run.thread_id
      |> Threads.list_messages_until(run.user_message_id)
      |> Enum.map(&Message.to_upstream/1)

    run.persona_snapshot
    |> Persona.from_snapshot()
    |> Personas.apply_to_request(%{
      "messages" => messages,
      "stream" => true,
      "stream_options" => %{"include_usage" => true}
    })
  end

  @impl true
  def handle_info({:cancel_run, run_id}, %{run_id: run_id} = state) do
    cancel_response(state)
    finish(state, :cancelled)
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil})}

  def handle_info(:heartbeat, state) do
    case Runs.heartbeat(state.run) do
      :ok ->
        {:noreply, state}

      {:error, :not_running} ->
        # Someone else ended the run (e.g. the janitor); there's nothing left to do.
        cancel_response(state)
        {:stop, :normal, %{state | run: nil}}
    end
  end

  def handle_info(:idle_timeout, state) do
    cancel_response(state)

    fail(state, %{
      "code" => "upstream_timeout",
      "message" => "The upstream stopped sending data."
    })
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, %{resp: %Req.Response{} = resp} = state) do
    case Req.parse_message(resp, message) do
      {:ok, items} ->
        handle_items(items, reset_idle_timer(state))

      {:error, reason} ->
        Logger.warning("Upstream stream failed: #{inspect(reason)}")
        fail(state, %{"code" => "upstream_error", "message" => "The upstream stream failed."})

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_items([], state), do: {:noreply, state}
  defp handle_items([:done | _rest], state), do: finish(state, :completed)

  defp handle_items([{:data, chunk} | rest], state) do
    {events, sse} = SSE.parse(state.sse, chunk)

    case handle_events(events, %{state | sse: sse}) do
      {:cont, state} -> handle_items(rest, state)
      {:done, state} -> finish(state, :completed)
      {:error, error, state} -> fail(state, error)
    end
  end

  defp handle_items([_other | rest], state), do: handle_items(rest, state)

  defp handle_events([], state), do: {:cont, maybe_flush(state)}
  defp handle_events(["[DONE]" | _rest], state), do: {:done, state}

  defp handle_events([data | rest], state) do
    case Jason.decode(data) do
      {:ok, %{"error" => error}} ->
        {:error, %{"code" => "upstream_error", "message" => upstream_error_message(error, nil)},
         state}

      {:ok, %{} = chunk} ->
        handle_events(rest, handle_chunk(chunk, state))

      _ ->
        Logger.warning("Ignoring unparseable upstream event: #{String.slice(data, 0, 200)}")
        handle_events(rest, state)
    end
  end

  defp handle_chunk(chunk, state) do
    state =
      case chunk do
        %{"usage" => %{} = usage} -> %{state | usage: usage}
        _ -> state
      end

    case chunk do
      %{"choices" => [%{} = choice | _]} ->
        delta = Map.get(choice, "delta") || %{}

        state
        |> add_delta(:text, :pending_text, delta["content"])
        |> add_delta(
          :reasoning,
          :pending_reasoning,
          delta["reasoning_content"] || delta["reasoning"]
        )
        |> Map.update!(:finish_reason, &(choice["finish_reason"] || &1))

      _ ->
        state
    end
  end

  defp add_delta(state, total_key, pending_key, text) when is_binary(text) and text != "" do
    state
    |> Map.update!(total_key, &[&1 | text])
    |> Map.update!(pending_key, &[&1 | text])
  end

  defp add_delta(state, _total_key, _pending_key, _text), do: state

  ## Deltas

  defp maybe_flush(state) do
    case config(:delta_flush_interval, 100) do
      0 ->
        flush(state)

      interval
      when is_nil(state.flush_timer) and
             (state.pending_text != [] or state.pending_reasoning != []) ->
        %{state | flush_timer: Process.send_after(self(), :flush, interval)}

      _ ->
        state
    end
  end

  defp flush(%{pending_text: [], pending_reasoning: []} = state), do: state

  defp flush(state) do
    if state.flush_timer, do: Process.cancel_timer(state.flush_timer)

    payload =
      %{
        "content" => IO.iodata_to_binary(state.pending_text),
        "reasoning" => IO.iodata_to_binary(state.pending_reasoning)
      }
      |> Map.reject(fn {_key, text} -> text == "" end)

    state
    |> emit("message.delta", payload)
    |> Map.merge(%{pending_text: [], pending_reasoning: [], flush_timer: nil})
  end

  defp emit(state, type, payload) do
    seq = state.seq + 1
    {:ok, _event} = Runs.append_event(state.run, seq, type, payload)
    %{state | seq: seq}
  end

  ## Finishing

  defp finish(state, status) do
    state = flush(state)
    text = IO.iodata_to_binary(state.text)
    reasoning = IO.iodata_to_binary(state.reasoning)

    message =
      if status == :completed or text != "" or reasoning != "" do
        content =
          [{"reasoning", reasoning}, {"text", text}]
          |> Enum.reject(fn {type, text} -> type == "reasoning" and text == "" end)
          |> Enum.map(fn {type, text} -> %{"type" => type, "text" => text} end)

        finish_reason = if status == :cancelled, do: "cancelled", else: state.finish_reason

        %{content: content, metadata: %{"finish_reason" => finish_reason}, usage: state.usage}
      end

    end_run(state, status, message: message, usage: state.usage)
  end

  defp fail(state, error) do
    end_run(flush(state), :failed, error: error)
  end

  defp end_run(state, status, opts) do
    case Runs.finish_run(state.run, status, Keyword.put(opts, :seq, state.seq)) do
      {:ok, _run, _message} -> :ok
      {:error, :not_active} -> :ok
    end

    {:stop, :normal, %{state | run: nil}}
  end

  @impl true
  def terminate(reason, %{run: %Run{} = run} = state) when reason != :normal do
    # Crashed or shut down mid-run: don't leave the run (and its thread) hanging.
    cancel_response(state)
    error = %{"code" => "interrupted", "message" => "The run was interrupted."}
    Runs.finish_run(run, :failed, error: error)
  rescue
    e -> Logger.error("Could not fail interrupted run: #{Exception.message(e)}")
  end

  def terminate(_reason, _state), do: :ok

  defp cancel_response(%{resp: %Req.Response{} = resp}), do: Req.cancel_async_response(resp)
  defp cancel_response(_state), do: :ok

  defp reset_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    timer = Process.send_after(self(), :idle_timeout, config(:idle_timeout, :timer.minutes(5)))
    %{state | idle_timer: timer}
  end

  defp upstream_error_message(%{"message" => message}, _status) when is_binary(message),
    do: message

  defp upstream_error_message(body, status) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) -> message
      {:ok, %{"error" => message}} when is_binary(message) -> message
      _ when is_integer(status) -> "The upstream responded with status #{status}."
      _ -> "The upstream returned an error."
    end
  end

  defp upstream_error_message(_error, _status), do: "The upstream returned an error."

  defp config(key, default), do: Runs.config(key, default)
end
