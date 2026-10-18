defmodule Meridian.Runs.StepTest do
  use ExUnit.Case, async: true

  import Meridian.Fixtures, only: [completion_events: 1, tool_call_events: 2]

  alias Meridian.Runs.Step

  # Feeds every chunk, returning the last result.
  defp feed_all(step, chunks) do
    Enum.reduce(chunks, {:cont, step}, fn chunk, {:cont, step} -> Step.feed(step, chunk) end)
  end

  defp event(data), do: "data: #{Jason.encode!(data)}\n\n"

  test "collects a streamed reply, its finish reason and usage" do
    assert {:done, step} = feed_all(Step.new(1), completion_events(["Hel", "lo"]))

    assert step.finish_reason == "stop"
    assert step.usage == %{"prompt_tokens" => 5, "completion_tokens" => 2, "total_tokens" => 7}
    assert Step.reply?(step)
    assert Step.content(step, true) == [%{"type" => "text", "text" => "Hello"}]
    assert Step.tool_calls(step) == []
  end

  test "events split across chunks are put back together" do
    body = completion_events(["Hello"]) |> IO.iodata_to_binary()
    {first, rest} = String.split_at(body, 17)

    assert {:cont, step} = Step.feed(Step.new(1), first)
    refute Step.reply?(step)
    assert {:done, step} = Step.feed(step, rest)
    assert Step.content(step, true) == [%{"type" => "text", "text" => "Hello"}]
  end

  test "keeps reasoning apart from text, under either field name" do
    deltas = [%{"reasoning_content" => "Hm"}, %{"reasoning" => "m."}, "Hi"]
    {:done, step} = feed_all(Step.new(1), completion_events(deltas))

    assert Step.content(step, true) == [
             %{"type" => "reasoning", "text" => "Hmm."},
             %{"type" => "text", "text" => "Hi"}
           ]
  end

  test "a final reply always has a text part; a reply that calls tools only if it said something" do
    {:done, step} = feed_all(Step.new(1), completion_events([]))
    refute Step.reply?(step)
    assert Step.content(step, true) == [%{"type" => "text", "text" => ""}]
    assert Step.content(step, false) == []
  end

  test "deltas are taken once" do
    {:cont, step} =
      Step.feed(Step.new(1), event(%{"choices" => [%{"delta" => %{"content" => "Hi"}}]}))

    assert Step.pending_delta?(step)

    assert {%{"content" => "Hi"}, step} = Step.take_delta(step)
    refute Step.pending_delta?(step)
    assert {nil, step} = Step.take_delta(step)

    # The whole reply is still there.
    assert Step.content(step, true) == [%{"type" => "text", "text" => "Hi"}]
  end

  test "assembles tool calls from their fragments, in order" do
    events =
      tool_call_events(
        [{"c1", "weather", ~s({"city": "Oslo"})}, {"c2", "time", ~s({"zone": "UTC"})}],
        ["Let me check."]
      )

    {:done, step} = feed_all(Step.new(1), events)
    assert step.finish_reason == "tool_calls"
    assert Step.content(step, false) == [%{"type" => "text", "text" => "Let me check."}]

    assert Step.tool_calls(step) == [
             %{
               "id" => "c1",
               "type" => "function",
               "function" => %{"name" => "weather", "arguments" => ~s({"city": "Oslo"})}
             },
             %{
               "id" => "c2",
               "type" => "function",
               "function" => %{"name" => "time", "arguments" => ~s({"zone": "UTC"})}
             }
           ]
  end

  test "tool calls without an id get one, and object arguments become JSON text" do
    call = %{"index" => 0, "function" => %{"name" => "roll", "arguments" => %{"sides" => 6}}}

    {:cont, step} =
      Step.feed(Step.new(1), event(%{"choices" => [%{"delta" => %{"tool_calls" => [call]}}]}))

    assert [%{"id" => "call_" <> _, "function" => function}] = Step.tool_calls(step)
    assert function == %{"name" => "roll", "arguments" => ~s({"sides":6})}
  end

  test "stops at an error event, or at one that isn't JSON" do
    assert {:upstream_error, %{"message" => "overloaded"}, _step} =
             Step.feed(Step.new(1), event(%{"error" => %{"message" => "overloaded"}}))

    assert {:invalid_event, "{nope", _step} = Step.feed(Step.new(1), "data: {nope\n\n")
  end

  test "add_usage/2 sums numbers and tolerates nil" do
    assert Step.add_usage(nil, nil) == nil
    assert Step.add_usage(%{"total_tokens" => 1}, nil) == %{"total_tokens" => 1}

    assert Step.add_usage(%{"total_tokens" => 1, "model" => "a"}, %{
             "total_tokens" => 2,
             "model" => "b"
           }) ==
             %{"total_tokens" => 3, "model" => "b"}
  end
end
