defmodule Meridian.Runs.RunServer do
  @moduledoc """
  Executes one run. Started by `Meridian.Runs.Worker` under `Meridian.Runs.Supervisor` and
  registered in `Meridian.Runs.Registry` by run id.

  A run is a loop of steps. Each step builds the request from the thread's history and the
  agent snapshot, streams the completion from the upstream, and either saves the reply (the
  run is done) or, if the model asked for tools, saves its message, runs the tools, saves their
  results, and starts the next step. The request runs in a separate process
  (`Meridian.Upstream.Stream`) that forwards the response here, and each tool call runs in its
  own task that sends its result here, so cancel requests, timers, response chunks, and tool
  results are all just messages, and this process never blocks waiting for them.

  A reply is only saved as completed if the upstream said the model finished (a
  `finish_reason`). A stream that ends without one, or that contains an event that isn't
  valid JSON, fails the run instead of saving a truncated reply. A tool failing is not the
  run failing: the model gets the error as the result. A run that needs more than
  `:max_steps` model calls fails.

  Enabled extensions (`Meridian.Extensions`) are called at each stage: `run_start`, then
  `before_run` (which may reject the run, and decides its tools), and in every step `context`
  and `before_model_request` while building the request, `message_end` before a reply is saved,
  `tool_call` and `tool_result` around each tool call, and `step_end`. `run_end` fires from
  `Meridian.Runs.finish_run/3`.

  Text and reasoning deltas are buffered and emitted as one `message.delta` event per
  `:delta_flush_interval` (milliseconds; `0` emits one event per upstream chunk), so the event
  log stays small and live clients and replaying clients see exactly the same events.
  """
  use GenServer, restart: :temporary

  require Logger

  alias Meridian.{Extensions, Agents, Runs, Skills, Threads, Upstream}
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
      # The run's system prompt, params, and tool definitions (from `before_run`), and its
      # tools by name.
      config: nil,
      tools: %{},
      step: 0,
      # Usage of the steps before this one.
      run_usage: nil,
      stream: nil,
      sse: SSE.new(),
      # This step's reply so far, and what hasn't been emitted as a delta yet (iodata).
      text: [],
      reasoning: [],
      pending_text: [],
      pending_reasoning: [],
      # Tool calls being streamed, by index: %{id, name, arguments (iodata)}.
      tool_calls: %{},
      finish_reason: nil,
      usage: nil,
      # Tool calls running: task ref => {call, task}.
      running_tools: %{},
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
            extensions: Extensions.enabled(ctx.agent)
        }

        Extensions.notify(state.extensions, :run_start, [], ctx)

        case configure(state) do
          {:ok, state} ->
            start_step(state)

          {:halt, reason} ->
            fail(state, %{"code" => "rejected", "message" => reason})
        end

      {:error, :not_queued} ->
        # Cancelled before it started, or already handled.
        {:stop, :normal, state}
    end
  end

  # `before_run` decides what holds for the whole run: the agent's system prompt (as
  # sections, with the index of its skills), its params, and the tools (the enabled
  # extensions', and `load_skill`).
  defp configure(%{ctx: ctx, extensions: extensions} = state) do
    agent = ctx.agent
    skills = Skills.enabled(agent)
    tool_set = Extensions.tool_set(extensions) ++ List.wrap(Skills.tool(skills))

    config = %{
      system_prompt: Enum.reject([agent.system_prompt, Skills.prompt_section(skills)], &is_nil/1),
      params: agent.params,
      tools: Enum.map(tool_set, & &1.definition)
    }

    with {:cont, config} <- Extensions.run(extensions, :before_run, config, ctx) do
      by_name = Map.new(tool_set, &{&1.name, &1})

      tools =
        Map.new(config.tools, fn definition ->
          {definition["name"], %{by_name[definition["name"]] | definition: definition}}
        end)

      {:ok, %{state | config: config, tools: tools}}
    end
  end

  defp start_step(state) do
    state = %{
      state
      | step: state.step + 1,
        sse: SSE.new(),
        text: [],
        reasoning: [],
        tool_calls: %{},
        finish_reason: nil,
        usage: nil
    }

    {:ok, stream} = Upstream.Stream.start_link(request_body(state))
    {:noreply, reset_idle_timer(%{state | stream: stream})}
  end

  # Every step's request is built the same way: `context` gets the conversation so far
  # (including earlier steps' tool calls and results), `before_model_request` the final body.
  defp request_body(%{run: run, ctx: ctx, extensions: extensions, config: config}) do
    history = run |> Threads.list_run_history() |> Message.to_upstream_history()
    {:cont, messages} = Extensions.run(extensions, :context, history, ctx)

    system_prompt =
      config.system_prompt |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n\n")

    body =
      %{ctx.agent | system_prompt: system_prompt, params: config.params}
      |> Agents.apply_to_request(%{
        "messages" => messages,
        "stream" => true,
        "stream_options" => %{"include_usage" => true}
      })
      |> put_tools(config.tools)

    {:cont, body} = Extensions.run(extensions, :before_model_request, body, ctx)
    body
  end

  defp put_tools(body, []), do: body

  defp put_tools(body, definitions),
    do: Map.put(body, "tools", Enum.map(definitions, &%{"type" => "function", "function" => &1}))

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

  # Between steps there's no stream, so a timer that fired just as one ended means nothing.
  def handle_info(:idle_timeout, %{stream: nil} = state), do: {:noreply, state}

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

  def handle_info({ref, result}, state) when is_map_key(state.running_tools, ref) do
    Process.demonitor(ref, [:flush])
    {{call, _task}, running} = Map.pop(state.running_tools, ref)

    result =
      case result do
        {:ok, text} -> {"ok", text}
        {:error, message} -> {"error", "Error: " <> message}
      end

    %{state | running_tools: running}
    |> tool_done(call, result)
    |> maybe_end_step()
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.running_tools, ref) do
    Logger.error("Tool call crashed: #{inspect(reason)}")
    {{call, _task}, running} = Map.pop(state.running_tools, ref)

    %{state | running_tools: running}
    |> tool_done(call, {"error", "Error: the tool crashed."})
    |> maybe_end_step()
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
        |> add_tool_call_deltas(delta["tool_calls"])
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

  # Tool calls stream in pieces: the id and name first, then the arguments (a JSON string) in
  # fragments, each piece saying which call (`index`) it belongs to.
  defp add_tool_call_deltas(state, [_ | _] = deltas) do
    deltas
    |> Enum.with_index()
    |> Enum.reduce(state, fn
      {%{} = delta, position}, state ->
        index = delta["index"] || position
        function = delta["function"] || %{}
        call = Map.get(state.tool_calls, index, %{id: nil, name: nil, arguments: []})

        call = %{
          call
          | id: call.id || non_empty(delta["id"]),
            name: call.name || non_empty(function["name"]),
            arguments: [call.arguments | arguments_fragment(function["arguments"])]
        }

        %{state | tool_calls: Map.put(state.tool_calls, index, call)}

      _other, state ->
        state
    end)
  end

  defp add_tool_call_deltas(state, _deltas), do: state

  defp non_empty(text) when is_binary(text) and text != "", do: text
  defp non_empty(_text), do: nil

  defp arguments_fragment(text) when is_binary(text), do: text
  # Some upstreams send the arguments as an object rather than as JSON text.
  defp arguments_fragment(%{} = arguments), do: Jason.encode!(arguments)
  defp arguments_fragment(_arguments), do: []

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

  defp complete(%{tool_calls: calls} = state) when map_size(calls) > 0, do: run_tools(state)
  defp complete(state), do: finish(state, :completed)

  ## Tools

  # The model asked for tools: save its message, then start every call. Calls that can't run
  # (unknown tool, bad arguments, blocked) get their error result right away.
  defp run_tools(state) do
    state = state |> flush() |> stop_idle_timer()

    if state.step >= config(:max_steps, 10) do
      fail(state, %{
        "code" => "too_many_steps",
        "message" => "The model kept calling tools for more than #{state.step} steps."
      })
    else
      calls =
        state.tool_calls
        |> Enum.sort()
        |> Enum.map(fn {_index, call} ->
          %{
            "id" =>
              call.id || "call_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
            "type" => "function",
            "function" => %{
              "name" => call.name || "",
              "arguments" => IO.iodata_to_binary(call.arguments)
            }
          }
        end)

      {:cont, content} =
        Extensions.run(state.extensions, :message_end, reply_content(state, false), state.ctx)

      seq = state.seq + 1

      {:ok, {_message, _event}} =
        Runs.add_message(
          state.run,
          seq,
          %{
            role: "assistant",
            content: content,
            tool_calls: calls,
            metadata: %{"finish_reason" => state.finish_reason},
            usage: state.usage
          },
          "message.completed"
        )

      state = %{
        state
        | seq: seq,
          run_usage: add_usage(state.run_usage, state.usage),
          usage: nil
      }

      calls
      |> Enum.reduce(state, &start_tool_call/2)
      |> maybe_end_step()
    end
  end

  defp start_tool_call(%{"id" => id, "function" => function}, state) do
    %{"name" => name, "arguments" => arguments} = function

    state =
      emit(state, "tool_call.started", %{"id" => id, "name" => name, "arguments" => arguments})

    call = %{"id" => id, "name" => name}

    with {:ok, tool} <- fetch_tool(state, name),
         {:ok, arguments} <- decode_arguments(arguments),
         call = Map.put(call, "arguments", arguments),
         {:ok, call} <- check_tool_call(state, call) do
      ctx = state.ctx

      task =
        Task.Supervisor.async_nolink(Meridian.Extensions.TaskSupervisor, fn ->
          execute_tool(tool, call["arguments"], ctx)
        end)

      %{state | running_tools: Map.put(state.running_tools, task.ref, {call, task})}
    else
      {:error, message} -> tool_done(state, call, {"error", "Error: " <> message})
    end
  end

  # `load_skill` is the core's own tool; every other tool is an extension's.
  defp execute_tool(%{skills: _} = tool, arguments, _ctx), do: Skills.load(tool, arguments)
  defp execute_tool(tool, arguments, ctx), do: Extensions.run_tool(tool, arguments, ctx)

  defp fetch_tool(state, name) do
    case Map.fetch(state.tools, name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, "there is no tool named #{inspect(name)}."}
    end
  end

  defp decode_arguments(arguments) do
    if String.trim(arguments) == "" do
      {:ok, %{}}
    else
      case Jason.decode(arguments) do
        {:ok, %{} = arguments} -> {:ok, arguments}
        _ -> {:error, "the arguments must be a JSON object."}
      end
    end
  end

  defp check_tool_call(state, call) do
    case Extensions.tool_call(state.extensions, call, state.ctx) do
      {:ok, call} -> {:ok, call}
      {:blocked, reason} -> {:error, "the call was blocked: #{reason}"}
    end
  end

  # A call has its result (`{status, text}`): pass it through `tool_result` and save it.
  defp tool_done(state, call, {status, text}) do
    max = config(:max_tool_result_chars, 20_000)

    text =
      if String.length(text) > max,
        do: String.slice(text, 0, max) <> "\n[Truncated: the result was over #{max} characters.]",
        else: text

    result = %{
      "id" => call["id"],
      "name" => call["name"],
      "arguments" => Map.get(call, "arguments", %{}),
      "content" => text,
      "status" => status
    }

    {:cont, result} = Extensions.run(state.extensions, :tool_result, result, state.ctx)
    seq = state.seq + 1

    {:ok, _} =
      Runs.add_message(
        state.run,
        seq,
        %{
          role: "tool",
          tool_call_id: call["id"],
          content: [%{"type" => "text", "text" => result["content"]}],
          metadata: %{"status" => status}
        },
        "tool_call.completed",
        %{"id" => call["id"], "name" => call["name"], "status" => status}
      )

    %{state | seq: seq}
  end

  # Once every call of the step has its result, the next step starts.
  defp maybe_end_step(%{running_tools: running} = state) when map_size(running) > 0,
    do: {:noreply, state}

  defp maybe_end_step(state) do
    end_step(state, "tool_calls")
    start_step(state)
  end

  defp end_step(state, finish_reason) do
    Extensions.notify(
      state.extensions,
      :step_end,
      [%{"index" => state.step, "finish_reason" => finish_reason}],
      state.ctx
    )
  end

  defp stop_tools(state) do
    Enum.each(state.running_tools, fn {_ref, {_call, task}} ->
      Task.shutdown(task, :brutal_kill)
    end)

    %{state | running_tools: %{}}
  end

  defp add_usage(nil, usage), do: usage
  defp add_usage(usage, nil), do: usage

  defp add_usage(total, usage) do
    Map.merge(total, usage, fn
      _key, a, b when is_integer(a) and is_integer(b) -> a + b
      _key, _a, b -> b
    end)
  end

  defp finish(state, status) do
    state = state |> stop_tools() |> flush()

    message =
      if status == :completed or state.text != [] or state.reasoning != [] do
        {:cont, content} =
          Extensions.run(state.extensions, :message_end, reply_content(state, true), state.ctx)

        finish_reason = if status == :cancelled, do: "cancelled", else: state.finish_reason

        %{content: content, metadata: %{"finish_reason" => finish_reason}, usage: state.usage}
      end

    if status == :completed, do: end_step(state, state.finish_reason)
    end_run(state, status, message: message, usage: add_usage(state.run_usage, state.usage))
  end

  # The step's reply as content parts. A final reply always has a text part, even if empty.
  defp reply_content(state, final?) do
    text = IO.iodata_to_binary(state.text)
    reasoning = IO.iodata_to_binary(state.reasoning)

    [{"reasoning", reasoning}, {"text", text}]
    |> Enum.reject(fn {type, text} -> text == "" and (type == "reasoning" or not final?) end)
    |> Enum.map(fn {type, text} -> %{"type" => type, "text" => text} end)
  end

  defp fail(state, error) do
    state = stop_tools(state)
    end_run(flush(state), :failed, error: error, usage: add_usage(state.run_usage, state.usage))
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
    stop_tools(state)
    error = %{"code" => "interrupted", "message" => "The run was interrupted."}
    Runs.finish_run(run, :failed, error: error)
  rescue
    e -> Logger.error("Could not fail interrupted run: #{Exception.message(e)}")
  end

  # However the run ended, close the upstream connection if it is still open.
  def terminate(_reason, state), do: cancel_stream(state)

  defp cancel_stream(%{stream: stream}) when is_pid(stream), do: Upstream.Stream.cancel(stream)
  defp cancel_stream(_state), do: :ok

  defp stop_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    cancel_stream(state)
    %{state | idle_timer: nil, stream: nil}
  end

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
