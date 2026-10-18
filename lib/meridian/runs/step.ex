defmodule Meridian.Runs.Step do
  @moduledoc """
  One step of a run: a model call's reply, put together as its streamed response arrives.

  A plain struct, with no process and no side effects: `Meridian.Runs.RunServer` feeds it the
  response body's chunks (`feed/2`) and decides what to do with what it collects: emitting
  deltas (`take_delta/1`), saving the reply (`content/2`), running the tools the model asked
  for (`tool_calls/1`).

  Text and reasoning are kept twice: the whole reply so far, and what hasn't been taken as a
  delta yet. Tool calls stream in pieces: the id and name first, then the arguments (a JSON
  string) in fragments, each piece saying which call (`index`) it belongs to.
  """

  alias Meridian.Upstream.SSE

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          sse: SSE.t(),
          text: iodata(),
          reasoning: iodata(),
          pending_text: iodata(),
          pending_reasoning: iodata(),
          tool_calls: %{
            non_neg_integer() => %{
              id: String.t() | nil,
              name: String.t() | nil,
              arguments: iodata()
            }
          },
          finish_reason: String.t() | nil,
          usage: map() | nil
        }

  defstruct index: 1,
            sse: %SSE{},
            text: [],
            reasoning: [],
            pending_text: [],
            pending_reasoning: [],
            tool_calls: %{},
            finish_reason: nil,
            usage: nil

  @doc "Step `index` of a run (from 1; 0 means no step yet), before any response arrived."
  @spec new(non_neg_integer()) :: t()
  def new(index), do: %__MODULE__{index: index}

  @doc """
  Adds a chunk of the response body. Returns `{:cont, step}`, or `{:done, step}` once the
  upstream sent `[DONE]`. An event carrying an error, or one that isn't JSON, stops there:
  `{:upstream_error, error, step}` or `{:invalid_event, data, step}`.
  """
  @spec feed(t(), binary()) ::
          {:cont | :done, t()}
          | {:upstream_error, term(), t()}
          | {:invalid_event, String.t(), t()}
  def feed(step, chunk) do
    {events, sse} = SSE.parse(step.sse, chunk)
    add_events(events, %{step | sse: sse})
  end

  defp add_events([], step), do: {:cont, step}
  defp add_events(["[DONE]" | _rest], step), do: {:done, step}

  defp add_events([data | rest], step) do
    case Jason.decode(data) do
      {:ok, %{"error" => error}} -> {:upstream_error, error, step}
      {:ok, %{} = chunk} -> add_events(rest, add_chunk(step, chunk))
      _ -> {:invalid_event, data, step}
    end
  end

  defp add_chunk(step, chunk) do
    step =
      case chunk do
        %{"usage" => %{} = usage} -> %{step | usage: usage}
        _ -> step
      end

    case chunk do
      %{"choices" => [%{} = choice | _]} ->
        delta = Map.get(choice, "delta") || %{}

        step
        |> add_delta(:text, :pending_text, delta["content"])
        |> add_delta(
          :reasoning,
          :pending_reasoning,
          delta["reasoning_content"] || delta["reasoning"]
        )
        |> add_tool_call_deltas(delta["tool_calls"])
        |> Map.update!(:finish_reason, &(choice["finish_reason"] || &1))

      _ ->
        step
    end
  end

  defp add_delta(step, total_key, pending_key, text) when is_binary(text) and text != "" do
    step
    |> Map.update!(total_key, &[&1, text])
    |> Map.update!(pending_key, &[&1, text])
  end

  defp add_delta(step, _total_key, _pending_key, _text), do: step

  defp add_tool_call_deltas(step, [_ | _] = deltas) do
    deltas
    |> Enum.with_index()
    |> Enum.reduce(step, fn
      {%{} = delta, position}, step ->
        index = delta["index"] || position
        function = delta["function"] || %{}
        call = Map.get(step.tool_calls, index, %{id: nil, name: nil, arguments: []})

        call = %{
          call
          | id: call.id || non_empty(delta["id"]),
            name: call.name || non_empty(function["name"]),
            arguments: [call.arguments | arguments_fragment(function["arguments"])]
        }

        %{step | tool_calls: Map.put(step.tool_calls, index, call)}

      _other, step ->
        step
    end)
  end

  defp add_tool_call_deltas(step, _deltas), do: step

  defp non_empty(text) when is_binary(text) and text != "", do: text
  defp non_empty(_text), do: nil

  defp arguments_fragment(text) when is_binary(text), do: text
  # Some upstreams send the arguments as an object rather than as JSON text.
  defp arguments_fragment(%{} = arguments), do: Jason.encode!(arguments)
  defp arguments_fragment(_arguments), do: []

  @doc "Whether there's text or reasoning that hasn't been taken as a delta yet."
  @spec pending_delta?(t()) :: boolean()
  def pending_delta?(step), do: step.pending_text != [] or step.pending_reasoning != []

  @doc """
  Takes what hasn't been taken yet, as a `message.delta` payload (`content`, `reasoning`;
  only those that aren't empty), or nil if there's nothing.
  """
  @spec take_delta(t()) :: {map() | nil, t()}
  def take_delta(step) do
    if pending_delta?(step) do
      payload =
        %{
          "content" => IO.iodata_to_binary(step.pending_text),
          "reasoning" => IO.iodata_to_binary(step.pending_reasoning)
        }
        |> Map.reject(fn {_key, text} -> text == "" end)

      {payload, %{step | pending_text: [], pending_reasoning: []}}
    else
      {nil, step}
    end
  end

  @doc "Whether the model said anything (text or reasoning)."
  @spec reply?(t()) :: boolean()
  def reply?(step), do: step.text != [] or step.reasoning != []

  @doc "The reply as content parts. A `final` reply always has a text part, even if empty."
  @spec content(t(), boolean()) :: [map()]
  def content(step, final?) do
    text = IO.iodata_to_binary(step.text)
    reasoning = IO.iodata_to_binary(step.reasoning)

    [{"reasoning", reasoning}, {"text", text}]
    |> Enum.reject(fn {type, text} -> text == "" and (type == "reasoning" or not final?) end)
    |> Enum.map(fn {type, text} -> %{"type" => type, "text" => text} end)
  end

  @doc """
  The tool calls the model asked for, in order, as Chat Completions `tool_calls`. A call the
  upstream sent without an id gets one.
  """
  @spec tool_calls(t()) :: [map()]
  def tool_calls(step) do
    step.tool_calls
    |> Enum.sort()
    |> Enum.map(fn {_index, call} ->
      %{
        "id" => call.id || "call_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
        "type" => "function",
        "function" => %{
          "name" => call.name || "",
          "arguments" => IO.iodata_to_binary(call.arguments)
        }
      }
    end)
  end

  @doc "Adds up two usage maps (either may be nil): numbers are summed, anything else replaced."
  @spec add_usage(map() | nil, map() | nil) :: map() | nil
  def add_usage(nil, usage), do: usage
  def add_usage(usage, nil), do: usage

  def add_usage(total, usage) do
    Map.merge(total, usage, fn
      _key, a, b when is_integer(a) and is_integer(b) -> a + b
      _key, _a, b -> b
    end)
  end
end
