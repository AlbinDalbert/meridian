defmodule Meridian.RunsTest do
  use Meridian.DataCase, async: true
  use Oban.Testing, repo: Meridian.Repo

  import Meridian.Fixtures

  @moduletag :capture_log

  alias Meridian.{Personas, Runs, Threads}
  alias Meridian.Runs.{Run, Worker}

  setup do
    user = user_fixture(%{}, %{"model" => "qwen"})

    {:ok, _} =
      user
      |> Personas.get_default_persona()
      |> Personas.update_persona(%{"system_prompt" => "Be brief.", "params" => %{"top_p" => 0.9}})

    %{user: user, thread: thread_fixture(user)}
  end

  defp execute(run), do: perform_job(Worker, %{"run_id" => run.id})

  defp event_types(run), do: run |> Runs.list_events() |> Enum.map(& &1.type)

  test "a run streams the reply from the upstream and saves it", %{thread: thread} do
    {_message, run} = message_fixture(thread, "Hi there")
    assert run.status == :queued
    assert_enqueued(worker: Worker, args: %{run_id: run.id}, queue: :runs)

    stub_upstream_stream(completion_events(["Hel", "lo!"]))
    Runs.subscribe(run)
    assert :ok = execute(run)

    assert_received {:upstream_request, body}

    assert body == %{
             "model" => "qwen",
             "top_p" => 0.9,
             "stream" => true,
             "stream_options" => %{"include_usage" => true},
             "messages" => [
               %{"role" => "system", "content" => "Be brief."},
               %{"role" => "user", "content" => "Hi there"}
             ]
           }

    run = Runs.get_run!(run.id)
    assert run.status == :completed
    assert run.usage["total_tokens"] == 7
    assert run.started_at && run.finished_at

    assert [_user, reply] = Threads.list_all_messages(thread)
    assert reply.role == "assistant"
    assert reply.run_id == run.id
    assert reply.content == [%{"type" => "text", "text" => "Hello!"}]
    assert reply.metadata == %{"finish_reason" => "stop"}

    events = Runs.list_events(run)
    assert Enum.map(events, & &1.seq) == Enum.to_list(1..length(events))

    assert Enum.map(events, & &1.type) ==
             ~w(run.started message.delta message.delta message.completed run.completed)

    assert Enum.map(events, & &1.payload["content"]) |> Enum.slice(1, 2) == ["Hel", "lo!"]

    # Live subscribers saw the same events, in order.
    for event <- events do
      seq = event.seq
      assert_received {:run_event, %{seq: ^seq}}
    end
  end

  test "the thread's history is sent upstream", %{thread: thread} do
    {_message, run} = message_fixture(thread, "One")
    stub_upstream_stream(completion_events(["First reply"]))
    :ok = execute(run)

    {_message, run} = message_fixture(thread, "Two")
    :ok = execute(run)

    assert_received {:upstream_request, _first}
    assert_received {:upstream_request, %{"messages" => messages}}

    assert Enum.map(messages, &{&1["role"], &1["content"]}) == [
             {"system", "Be brief."},
             {"user", "One"},
             {"assistant", "First reply"},
             {"user", "Two"}
           ]
  end

  test "reasoning is kept as a separate part and not sent back upstream", %{thread: thread} do
    {_message, run} = message_fixture(thread)

    stub_upstream_stream(
      completion_events([%{"reasoning_content" => "Thinking."}, "Answer", %{"reasoning" => "?"}])
    )

    :ok = execute(run)

    assert [_user, reply] = Threads.list_all_messages(thread)

    assert reply.content == [
             %{"type" => "reasoning", "text" => "Thinking.?"},
             %{"type" => "text", "text" => "Answer"}
           ]

    assert Threads.Message.to_upstream(reply) == %{"role" => "assistant", "content" => "Answer"}
  end

  test "the persona is frozen when the run is created", %{user: user, thread: thread} do
    {_message, run} = message_fixture(thread)

    {:ok, _} =
      user
      |> Personas.get_default_persona()
      |> Personas.update_persona(%{"model" => "other"}, force: true)

    stub_upstream_stream(completion_events(["ok"]))
    :ok = execute(run)
    assert_received {:upstream_request, %{"model" => "qwen"}}
  end

  test "an upstream error response fails the run", %{thread: thread} do
    {_message, run} = message_fixture(thread)

    Req.Test.stub(Meridian.Upstream, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => %{"message" => "context too long"}})
    end)

    :ok = execute(run)

    run = Runs.get_run!(run.id)
    assert run.status == :failed

    assert run.error == %{
             "code" => "upstream_error",
             "message" => "context too long",
             "status" => 400
           }

    assert event_types(run) == ~w(run.started run.failed)
    assert [_user] = Threads.list_all_messages(thread)
  end

  test "an error event mid-stream fails the run", %{thread: thread} do
    {_message, run} = message_fixture(thread)

    stub_upstream_stream([
      ~s(data: {"choices":[{"delta":{"content":"Par"}}]}\n\n),
      ~s(data: {"error":{"message":"overloaded"}}\n\n)
    ])

    :ok = execute(run)

    run = Runs.get_run!(run.id)
    assert run.status == :failed
    assert run.error["message"] == "overloaded"
    assert event_types(run) == ~w(run.started message.delta run.failed)
  end

  test "an unreachable upstream fails the run", %{thread: thread} do
    {_message, run} = message_fixture(thread)
    stub_upstream_down()

    :ok = execute(run)

    assert %Run{status: :failed, error: %{"code" => "upstream_unavailable"}} =
             Runs.get_run!(run.id)
  end

  test "a thread has at most one active run", %{thread: thread} do
    {_message, run} = message_fixture(thread)

    assert {:error, :run_active} =
             Threads.send_message(thread, %Meridian.Accounts.ApiKey.Policy{}, %{"content" => "x"})

    # Nothing from the rejected message was saved.
    assert [_message] = Threads.list_all_messages(thread)

    stub_upstream_stream(completion_events(["ok"]))
    :ok = execute(run)
    assert {_message, _run} = message_fixture(thread, "Again")
  end

  describe "cancel_run/1" do
    test "cancels a queued run right away, and the job then does nothing", %{thread: thread} do
      {_message, run} = message_fixture(thread)

      assert {:ok, %Run{status: :cancelled}} = Runs.cancel_run(run)
      assert event_types(run) == ~w(run.cancelled)

      :ok = execute(run)
      assert Runs.get_run!(run.id).status == :cancelled
      refute_received {:upstream_request, _body}
    end

    test "stops a running run", %{thread: thread} do
      {_message, run} = message_fixture(thread)
      test_pid = self()

      Req.Test.stub(Meridian.Upstream, fn conn ->
        send(test_pid, {:upstream_called, self()})
        assert_receive :continue

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, Enum.join(completion_events(["never seen"])))
      end)

      task = Task.async(fn -> execute(run) end)
      assert_receive {:upstream_called, server_pid}

      # The cancel request reaches the RunServer before any of the response does.
      run = Runs.get_run!(run.id)
      assert run.status == :running
      assert {:ok, _run} = Runs.cancel_run(run)
      send(server_pid, :continue)
      assert :ok = Task.await(task)

      assert Runs.get_run!(run.id).status == :cancelled
      assert event_types(run) == ~w(run.started run.cancelled)
      assert [_user] = Threads.list_all_messages(thread)
    end

    test "does nothing to a finished run", %{thread: thread} do
      {_message, run} = message_fixture(thread)
      stub_upstream_stream(completion_events(["ok"]))
      :ok = execute(run)

      run = Runs.get_run!(run.id)
      assert {:ok, %Run{status: :completed}} = Runs.cancel_run(run)
    end
  end

  test "fail_stale_runs/1 fails runs whose heartbeat stopped", %{thread: thread} do
    {_message, run} = message_fixture(thread)
    {:ok, run, _started} = Runs.start_run(run.id)

    assert Runs.fail_stale_runs(60_000) == 0

    stale = DateTime.add(DateTime.utc_now(), -120, :second)
    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [heartbeat_at: stale])

    assert Runs.fail_stale_runs(60_000) == 1
    assert %Run{status: :failed, error: %{"code" => "interrupted"}} = Runs.get_run!(run.id)
    assert event_types(run) == ~w(run.started run.failed)

    # The thread is free again.
    assert {_message, _run} = message_fixture(thread, "Again")
  end
end
