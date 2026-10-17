defmodule Meridian.Runs.RunServer do
  @moduledoc """
  Executes one run. Started by `Meridian.Runs.Worker` under `Meridian.Runs.Supervisor` and
  registered in `Meridian.Runs.Registry` by run id.

  The run is a single model call for now: build the context from the thread's history, apply
  the persona snapshot, stream the completion from the upstream, and save the reply. The
  request runs in a separate process (`Meridian.Upstream.Stream`) that forwards the response
  here, so cancel requests, timers, and response chunks are all just messages, and this
  process never blocks waiting for the upstream.

  A reply is only saved as completed if the upstream said the model finished (a
  `finish_reason`). A stream that ends without one, or that contains an event that isn't
  valid JSON, fails the run instead of saving a truncated reply.

  Enabled extensions (`Meridian.Extensions`) are called at each stage: `run_start`, then
  `before_run` (which may reject the run), `context` and `before_model_request` while building
  the request, and `message_end` before the reply is saved. `run_end` fires from `Meridian.Runs.finish_run/3`.

  Text and reasoning deltas are buffered and emitted as one `message.delta` event per
  `:delta_flush_interval` (milliseconds; `0` emits one event per upstream chunk), so the event
  log stays small and live clients and replaying clients see exactly the same events.
  """
  use GenServer, restart: :temporary

  require Logger

  alias Meridian.{Extensions, Personas, Runs, Threads, Upstream}
  alias Meridian.Extensions.Context
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
      # Enabled extensions and their hook context, set once the run has started.
      extensions: [],
      ctx: nil,
      stream: nil,
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
        ctx = Context.for_run(run)

        state = %{
          state
          | run: run,
            seq: started.seq,
            ctx: ctx,
            extensions: Extensions.enabled(ctx.persona)
        }

        Extensions.notify(state.extensions, :run_start, [], ctx)

        case request_body(state) do
          {:ok, body} ->
            request(state, body)

          {:halt, reason} ->
            fail(state, %{"code" => "rejected", "message" => reason})
        end

      {:error, :not_queued} ->
        # Cancelled before it started, or already handled.
        {:stop, :normal, state}
    end
  end

  defp request(state, body) do
    {:ok, stream} = Upstream.Stream.start_link(body)
    {:noreply, reset_idle_timer(%{state | stream: stream})}
  end

  # Extensions shape the request in three steps: `before_run` the persona's system prompt
  # (as sections) and params, `context` the history, `before_model_request` the final body.
  defp request_body(%{run: run, ctx: ctx, extensions: extensions}) do
    persona = ctx.persona
    config = %{system_prompt: [persona.system_prompt], params: persona.params}

    with {:cont, config} <- Extensions.run(extensions, :before_run, config, ctx) do
      history =
        run.thread_id
        |> Threads.list_messages_until(run.user_message_id)
        |> Enum.map(&Message.to_upstream/1)

      {:cont, messages} = Extensions.run(extensions, :context, history, ctx)

      system_prompt =
        config.system_prompt |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n\n")

      body =
        %{persona | system_prompt: system_prompt, params: config.params}
        |> Personas.apply_to_request(%{
          "messages" => messages,
          "stream" => true,
          "stream_options" => %{"include_usage" => true}
        })

      {:cont, body} = Extensions.run(extensions, :before_model_request, body, ctx)
      {:ok, body}
    end
  end

  @impl true
  def handle_info({:cancel_run, run_id}, %{run_id: run_id} = state) do
    finish(state, :cancelled)
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil})}

  def handle_info(:heartbeat, state) do
    case Runs.heartbeat(state.run) do
      :ok ->
        {:noreply, state}

      {:error, :not_running} ->
        # Someone else ended the run (e.g. the janitor); there's nothing left to do.
        {:stop, :normal, %{state | run: nil}}
    end
  end

  def handle_info(:idle_timeout, state) do
    fail(state, %{
      "code" => "upstream_timeout",
      "message" => "The upstream stopped sending data."
    })
  end

  def handle_info({:upstream, stream, message}, %{stream: stream} = state) do
    handle_upstream(message, state)
  end

  def handle_info({:EXIT, stream, reason}, %{stream: stream} = state) when reason != :normal do
    Logger.error("Upstream stream crashed: #{inspect(reason)}")

    fail(%{state | stream: nil}, %{
      "code" => "upstream_error",
      "message" => "The upstream stream failed."
    })
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_upstream({:items, items}, state), do: handle_items(items, reset_idle_timer(state))

  defp handle_upstream({:error_response, status, body}, state) do
    body = String.slice(body, 0, 2000)
    Logger.warning("Upstream responded #{status}: #{body}")

    fail(state, %{
      "code" => "upstream_error",
      "message" => upstream_error_message(body, status),
      "status" => status
    })
  end

  defp handle_upstream({:request_failed, :not_configured}, state) do
    fail(state, %{"code" => "upstream_not_configured", "message" => "No upstream is configured."})
  end

  defp handle_upstream({:request_failed, reason}, state) do
    Logger.warning("Upstream request failed: #{inspect(reason)}")
    fail(state, %{"code" => "upstream_unavailable", "message" => "The upstream is unavailable."})
  end

  defp handle_upstream({:stream_failed, reason}, state) do
    Logger.warning("Upstream stream failed: #{inspect(reason)}")
    fail(state, %{"code" => "upstream_error", "message" => "The upstream stream failed."})
  end

  defp handle_items([], state), do: {:noreply, state}
  # The response body ended. Without a [DONE] event first, this is only a success if the
  # model said it finished.
  defp handle_items([:done | _rest], state), do: complete(state)

  defp handle_items([{:data, chunk} | rest], state) do
    {events, sse} = SSE.parse(state.sse, chunk)

    case handle_events(events, %{state | sse: sse}) do
      {:cont, state} -> handle_items(rest, state)
      {:done, state} -> complete(state)
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
        Logger.warning("Unparseable upstream event: #{String.slice(data, 0, 200)}")

        {:error,
         %{"code" => "upstream_error", "message" => "The upstream sent an invalid event."}, state}
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
    |> Map.update!(total_key, &[&1, text])
    |> Map.update!(pending_key, &[&1, text])
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

  # The upstream stream ended ([DONE] or end of body). Only a model that reported why it
  # stopped has finished its reply; anything else is a truncated stream.
  defp complete(%{finish_reason: nil} = state) do
    fail(state, %{
      "code" => "upstream_incomplete",
      "message" => "The upstream ended the response before the model finished."
    })
  end

  defp complete(state), do: finish(state, :completed)

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

        {:cont, content} = Extensions.run(state.extensions, :message_end, content, state.ctx)

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
    cancel_stream(state)
    error = %{"code" => "interrupted", "message" => "The run was interrupted."}
    Runs.finish_run(run, :failed, error: error)
  rescue
    e -> Logger.error("Could not fail interrupted run: #{Exception.message(e)}")
  end

  # However the run ended, close the upstream connection if it is still open.
  def terminate(_reason, state), do: cancel_stream(state)

  defp cancel_stream(%{stream: stream}) when is_pid(stream), do: Upstream.Stream.cancel(stream)
  defp cancel_stream(_state), do: :ok

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
