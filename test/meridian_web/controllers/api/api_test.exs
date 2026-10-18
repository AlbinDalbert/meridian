defmodule MeridianWeb.ApiTest do
  use MeridianWeb.ConnCase, async: true
  use Oban.Testing, repo: Meridian.Repo

  import Meridian.Fixtures

  alias Meridian.Runs
  alias Meridian.Runs.Worker

  @moduletag :capture_log

  setup %{conn: conn} do
    user = user_fixture(%{}, %{"model" => "qwen"})
    coder = agent_fixture(user, %{"slug" => "coder"})
    api_key = api_key_fixture(user)

    %{conn: authed(conn, api_key), user: user, coder: coder}
  end

  defp authed(conn, api_key), do: put_req_header(conn, "authorization", "Bearer #{api_key.token}")

  defp execute(run_id), do: perform_job(Worker, %{"run_id" => run_id})

  # Parses an SSE body into [{id, event, data}].
  defp sse_events(body) do
    for block <- String.split(body, "\n\n", trim: true), not String.starts_with?(block, ":") do
      fields =
        for line <- String.split(block, "\n"), into: %{} do
          [key, value] = String.split(line, ": ", parts: 2)
          {key, value}
        end

      {String.to_integer(fields["id"]), fields["event"], Jason.decode!(fields["data"])}
    end
  end

  defp create_thread(conn, attrs \\ %{}) do
    conn |> post(~p"/api/threads", attrs) |> json_response(201) |> Map.fetch!("data")
  end

  defp send_message(conn, thread_id, content) do
    conn
    |> post(~p"/api/threads/#{thread_id}/messages", %{"content" => content})
    |> json_response(202)
    |> Map.fetch!("data")
  end

  test "requires an API key" do
    conn = get(build_conn(), ~p"/api/threads")
    assert %{"error" => %{"code" => "missing_api_key"}} = json_response(conn, 401)
  end

  describe "agents" do
    test "list the ones the key allows, marking the default", %{conn: conn, user: user} do
      assert %{"data" => [default, coder]} = conn |> get(~p"/api/agents") |> json_response(200)
      assert %{"id" => "meridian/default", "model" => "qwen", "default" => true} = default
      assert %{"id" => "meridian/coder", "default" => false} = coder

      restricted =
        api_key_fixture(user, %{
          "policy" => %{"allowed_agents" => ["coder"], "default_agent" => "coder"}
        })

      assert %{"data" => [%{"id" => "meridian/coder", "default" => true}]} =
               conn |> authed(restricted) |> get(~p"/api/agents") |> json_response(200)
    end
  end

  describe "threads" do
    test "create, list, show, update, delete", %{conn: conn} do
      thread = create_thread(conn, %{"title" => "Plans"})
      assert thread["agent"] == "meridian/default"
      assert thread["title"] == "Plans"

      assert %{"data" => [%{"id" => id}]} = conn |> get(~p"/api/threads") |> json_response(200)
      assert id == thread["id"]

      assert %{"data" => %{"active_run" => nil}} =
               conn |> get(~p"/api/threads/#{id}") |> json_response(200)

      assert %{"data" => %{"title" => "Renamed", "agent" => "meridian/coder"}} =
               conn
               |> patch(~p"/api/threads/#{id}", %{"title" => "Renamed", "agent" => "coder"})
               |> json_response(200)

      assert conn |> delete(~p"/api/threads/#{id}") |> response(204)
      assert conn |> get(~p"/api/threads/#{id}") |> json_response(404)
    end

    test "accept an agent model id", %{conn: conn} do
      assert %{"agent" => "meridian/coder"} =
               create_thread(conn, %{"agent" => "meridian/coder"})
    end

    test "only use agents the key allows", %{conn: conn, user: user} do
      restricted = api_key_fixture(user, %{"policy" => %{"allowed_agents" => ["default"]}})
      conn = authed(conn, restricted)

      assert %{"error" => %{"code" => "agent_not_found"}} =
               conn |> post(~p"/api/threads", %{"agent" => "coder"}) |> json_response(422)

      assert %{"agent" => "meridian/default"} = create_thread(conn)
    end

    test "of other users are not visible", %{conn: conn} do
      other = user_fixture()
      thread = thread_fixture(other)

      assert conn |> get(~p"/api/threads/#{thread.id}") |> json_response(404)
      assert conn |> get(~p"/api/threads/#{thread.id}/messages") |> json_response(404)
      assert conn |> get(~p"/api/threads/not-a-uuid") |> json_response(404)
      assert %{"data" => []} = conn |> get(~p"/api/threads") |> json_response(200)
    end

    test "can't be deleted with an active run", %{conn: conn} do
      thread = create_thread(conn)
      send_message(conn, thread["id"], "Hi")

      assert %{"error" => %{"code" => "run_active"}} =
               conn |> delete(~p"/api/threads/#{thread["id"]}") |> json_response(409)
    end
  end

  describe "messages" do
    test "sending a message starts a run; the reply is in the history", %{conn: conn} do
      thread = create_thread(conn)

      assert %{"message" => message, "run" => run} = send_message(conn, thread["id"], "Hi")
      assert message["role"] == "user"
      assert message["content"] == [%{"type" => "text", "text" => "Hi"}]
      assert run["status"] == "queued"
      assert run["agent"] == "meridian/default"

      assert %{"data" => %{"active_run" => %{"id" => run_id}}} =
               conn |> get(~p"/api/threads/#{thread["id"]}") |> json_response(200)

      assert run_id == run["id"]

      assert %{"error" => %{"code" => "run_active"}} =
               conn
               |> post(~p"/api/threads/#{thread["id"]}/messages", %{"content" => "Again"})
               |> json_response(409)

      stub_upstream_stream(completion_events(["Hello", "!"]))
      :ok = execute(run_id)

      assert %{"data" => %{"status" => "completed", "usage" => %{"total_tokens" => 7}}} =
               conn |> get(~p"/api/runs/#{run_id}") |> json_response(200)

      assert %{"data" => [_user, reply], "has_more" => false} =
               conn |> get(~p"/api/threads/#{thread["id"]}/messages") |> json_response(200)

      assert reply["role"] == "assistant"
      assert reply["run_id"] == run_id
      assert reply["content"] == [%{"type" => "text", "text" => "Hello!"}]
    end

    test "rejects empty content", %{conn: conn} do
      thread = create_thread(conn)

      for content <- ["", "  ", [], [%{"type" => "audio"}], nil] do
        assert %{"error" => %{"code" => "invalid_request"}} =
                 conn
                 |> post(~p"/api/threads/#{thread["id"]}/messages", %{"content" => content})
                 |> json_response(422)
      end
    end

    test "are paginated with before and limit", %{conn: conn, user: user} do
      thread = thread_fixture(user)
      stub_upstream_stream(completion_events(["ok"]))

      for n <- 1..3 do
        {_message, run} = message_fixture(thread, "m#{n}")
        :ok = execute(run.id)
      end

      path = ~p"/api/threads/#{thread.id}/messages"

      assert %{"data" => page, "has_more" => true} =
               conn |> get(path, %{"limit" => "4"}) |> json_response(200)

      texts = fn messages -> Enum.map(messages, &(&1["content"] |> hd() |> Map.get("text"))) end
      assert texts.(page) == ["m2", "ok", "m3", "ok"]

      assert %{"data" => older, "has_more" => false} =
               conn
               |> get(path, %{"limit" => "4", "before" => hd(page)["id"]})
               |> json_response(200)

      assert texts.(older) == ["m1", "ok"]
    end
  end

  describe "reshaping threads" do
    # A thread with two finished turns: Q1/A1, Q2/A2.
    setup %{conn: conn} do
      thread = create_thread(conn, %{"title" => "Original"})
      stub_upstream_streams([completion_events(["A1"]), completion_events(["A2"])])

      for q <- ["Q1", "Q2"] do
        %{"run" => %{"id" => run_id}} = send_message(conn, thread["id"], q)
        :ok = execute(run_id)
      end

      %{thread: thread}
    end

    defp messages(conn, thread_id) do
      conn
      |> get(~p"/api/threads/#{thread_id}/messages")
      |> json_response(200)
      |> Map.fetch!("data")
    end

    defp texts(messages), do: Enum.map(messages, &(&1["content"] |> hd() |> Map.get("text")))

    # The user and assistant texts a run sent upstream.
    defp upstream_texts do
      assert_receive {:upstream_request, %{"messages" => messages}}

      for %{"role" => role, "content" => text} <- messages,
          role in ["user", "assistant"],
          do: text
    end

    test "truncate and reply reroll the last reply", %{conn: conn, thread: thread} do
      [_q1, _a1, q2, a2] = messages(conn, thread["id"])
      flush_upstream_requests()

      assert conn
             |> post(~p"/api/threads/#{thread["id"]}/truncate", %{"after" => q2["id"]})
             |> response(204)

      assert texts(messages(conn, thread["id"])) == ["Q1", "A1", "Q2"]

      stub_upstream_stream(completion_events(["A2 again"]))

      assert %{"data" => %{"id" => run_id, "status" => "queued", "user_message_id" => q2_id}} =
               conn |> post(~p"/api/threads/#{thread["id"]}/reply") |> json_response(202)

      assert q2_id == q2["id"]
      :ok = execute(run_id)

      assert upstream_texts() == ["Q1", "A1", "Q2"]
      assert texts(messages(conn, thread["id"])) == ["Q1", "A1", "Q2", "A2 again"]

      # The replaced reply's run is kept.
      assert %{"data" => %{"status" => "completed"}} =
               conn |> get(~p"/api/runs/#{a2["run_id"]}") |> json_response(200)
    end

    test "reply needs a user message waiting for one", %{conn: conn, thread: thread} do
      assert %{"error" => %{"code" => "nothing_to_reply"}} =
               conn |> post(~p"/api/threads/#{thread["id"]}/reply") |> json_response(409)

      empty = create_thread(conn)

      assert %{"error" => %{"code" => "nothing_to_reply"}} =
               conn |> post(~p"/api/threads/#{empty["id"]}/reply") |> json_response(409)
    end

    test "truncating deletes the runs of deleted user messages", %{conn: conn, thread: thread} do
      [_q1, a1, _q2, a2] = messages(conn, thread["id"])

      assert conn
             |> post(~p"/api/threads/#{thread["id"]}/truncate", %{"after" => a1["id"]})
             |> response(204)

      assert texts(messages(conn, thread["id"])) == ["Q1", "A1"]
      assert conn |> get(~p"/api/runs/#{a2["run_id"]}") |> json_response(404)
    end

    test "truncate needs one of the thread's messages and no active run", %{
      conn: conn,
      thread: thread
    } do
      [q1 | _] = messages(conn, thread["id"])
      other = create_thread(conn)
      path = ~p"/api/threads/#{other["id"]}/truncate"

      for after_id <- [q1["id"], "nope", nil] do
        assert conn |> post(path, %{"after" => after_id}) |> json_response(404)
      end

      %{"message" => q} = send_message(conn, other["id"], "Hi")

      assert %{"error" => %{"code" => "run_active"}} =
               conn |> post(path, %{"after" => q["id"]}) |> json_response(409)
    end

    test "fork copies the history through a message", %{conn: conn, thread: thread} do
      [q1, a1, q2, _a2] = original = messages(conn, thread["id"])
      flush_upstream_requests()

      assert %{"data" => fork} =
               conn
               |> post(~p"/api/threads/#{thread["id"]}/fork", %{"through" => q2["id"]})
               |> json_response(201)

      assert fork["id"] != thread["id"]
      assert fork["title"] == "Original"
      assert fork["agent"] == thread["agent"]

      copies = messages(conn, fork["id"])
      assert texts(copies) == ["Q1", "A1", "Q2"]
      assert Enum.all?(copies, &(&1["thread_id"] == fork["id"] and &1["run_id"] == nil))
      assert Enum.map(copies, & &1["inserted_at"]) == Enum.map([q1, a1, q2], & &1["inserted_at"])
      assert messages(conn, thread["id"]) == original

      # The fork ends on a user message, so it can be answered.
      stub_upstream_stream(completion_events(["A2 elsewhere"]))

      assert %{"data" => %{"id" => run_id}} =
               conn |> post(~p"/api/threads/#{fork["id"]}/reply") |> json_response(202)

      :ok = execute(run_id)
      assert upstream_texts() == ["Q1", "A1", "Q2"]
      assert texts(messages(conn, fork["id"])) == ["Q1", "A1", "Q2", "A2 elsewhere"]
    end

    test "fork without through copies everything", %{conn: conn, thread: thread} do
      assert %{"data" => fork} =
               conn |> post(~p"/api/threads/#{thread["id"]}/fork") |> json_response(201)

      assert texts(messages(conn, fork["id"])) == ["Q1", "A1", "Q2", "A2"]
    end

    test "fork needs one of the thread's messages", %{conn: conn, thread: thread} do
      other = create_thread(conn)
      %{"message" => q} = send_message(conn, other["id"], "Hi")

      for through <- [q["id"], "nope"] do
        assert conn
               |> post(~p"/api/threads/#{thread["id"]}/fork", %{"through" => through})
               |> json_response(404)
      end
    end

    test "other users' threads can't be reshaped", %{thread: thread} do
      stranger = authed(build_conn(), api_key_fixture(user_fixture()))

      for action <- ["fork", "truncate", "reply"] do
        assert stranger |> post("/api/threads/#{thread["id"]}/#{action}") |> json_response(404)
      end
    end
  end

  defp flush_upstream_requests do
    receive do
      {:upstream_request, _} -> flush_upstream_requests()
    after
      0 -> :ok
    end
  end

  describe "run events (SSE)" do
    setup %{conn: conn} do
      thread = create_thread(conn)
      %{"run" => %{"id" => run_id}} = send_message(conn, thread["id"], "Hi")
      %{run_id: run_id}
    end

    test "replays a finished run's events and ends the stream", %{conn: conn, run_id: run_id} do
      stub_upstream_stream(completion_events(["Hel", "lo"]))
      :ok = execute(run_id)

      conn = get(conn, ~p"/api/runs/#{run_id}/events")
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]

      events = sse_events(response(conn, 200))

      assert Enum.map(events, fn {id, type, _data} -> {id, type} end) == [
               {1, "run.started"},
               {2, "message.delta"},
               {3, "message.delta"},
               {4, "message.completed"},
               {5, "run.completed"}
             ]

      assert {2, _, %{"seq" => 2, "run_id" => ^run_id, "payload" => %{"content" => "Hel"}}} =
               Enum.at(events, 1)
    end

    test "resumes after Last-Event-ID or ?after", %{conn: conn, run_id: run_id} do
      stub_upstream_stream(completion_events(["Hel", "lo"]))
      :ok = execute(run_id)

      resumed =
        conn
        |> put_req_header("last-event-id", "3")
        |> get(~p"/api/runs/#{run_id}/events")
        |> response(200)
        |> sse_events()

      assert Enum.map(resumed, &elem(&1, 0)) == [4, 5]

      assert conn
             |> get(~p"/api/runs/#{run_id}/events", %{"after" => "4"})
             |> response(200)
             |> sse_events()
             |> Enum.map(&elem(&1, 0)) == [5]

      assert %{"error" => %{"code" => "invalid_cursor"}} =
               conn
               |> get(~p"/api/runs/#{run_id}/events", %{"after" => "x"})
               |> json_response(400)
    end

    test "streams a run in progress until it ends", %{conn: conn, run_id: run_id} do
      test_pid = self()

      Req.Test.stub(Meridian.Upstream, fn upstream_conn ->
        send(test_pid, {:upstream_called, self()})
        assert_receive :continue

        upstream_conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, Enum.join(completion_events(["Hi"])))
      end)

      run_task = Task.async(fn -> execute(run_id) end)
      assert_receive {:upstream_called, server_pid}, 2000

      # The run has started but not finished: the client sees what exists so far, then the
      # rest live.
      sse_task =
        Task.async(fn -> conn |> get(~p"/api/runs/#{run_id}/events") |> response(200) end)

      send(server_pid, :continue)
      :ok = Task.await(run_task)

      events = sse_task |> Task.await() |> sse_events()
      assert Enum.map(events, &elem(&1, 0)) == [1, 2, 3, 4]
      assert {4, "run.completed", _data} = List.last(events)
    end

    test "cancelling a queued run ends its stream", %{conn: conn, run_id: run_id} do
      assert %{"data" => %{"status" => "cancelled"}} =
               conn |> post(~p"/api/runs/#{run_id}/cancel") |> json_response(202)

      assert [{1, "run.cancelled", _data}] =
               conn |> get(~p"/api/runs/#{run_id}/events") |> response(200) |> sse_events()
    end

    test "a reconnect after the run ended gets 204, so EventSource stops", %{
      conn: conn,
      run_id: run_id
    } do
      stub_upstream_stream(completion_events(["ok"]))
      :ok = execute(run_id)

      conn = conn |> put_req_header("last-event-id", "4") |> get(~p"/api/runs/#{run_id}/events")
      assert response(conn, 204) == ""
    end

    test "browsers can authenticate with the run's events token", %{conn: conn, user: user} do
      thread = create_thread(conn)
      %{"run" => run} = send_message(conn, thread["id"], "Hi")
      assert is_binary(run["events_token"])

      assert %{"data" => %{"events_token" => _}} =
               conn |> get(~p"/api/runs/#{run["id"]}") |> json_response(200)

      assert %{"data" => %{"active_run" => %{"events_token" => _}}} =
               conn |> get(~p"/api/threads/#{thread["id"]}") |> json_response(200)

      stub_upstream_stream(completion_events(["ok"]))
      :ok = execute(run["id"])

      path = ~p"/api/runs/#{run["id"]}/events"

      assert [{1, "run.started", _} | _] =
               build_conn()
               |> get(path, %{"token" => run["events_token"]})
               |> response(200)
               |> sse_events()

      # Not valid for another run, for other endpoints, or once garbled.
      %{"run" => other_run} = send_message(conn, create_thread(conn)["id"], "Hi")

      assert %{"error" => %{"code" => "invalid_api_key"}} =
               build_conn()
               |> get(~p"/api/runs/#{other_run["id"]}/events", %{"token" => run["events_token"]})
               |> json_response(401)

      assert build_conn()
             |> get(~p"/api/runs/#{run["id"]}", %{"token" => run["events_token"]})
             |> json_response(401)

      assert build_conn() |> get(path, %{"token" => "nope"}) |> json_response(401)

      # Revoking the key revokes its tokens.
      [api_key] = Meridian.Accounts.list_api_keys(user)
      {:ok, _} = Meridian.Accounts.revoke_api_key(api_key)

      assert build_conn() |> get(path, %{"token" => run["events_token"]}) |> json_response(401)
    end

    test "of other users' runs are not visible", %{run_id: run_id} do
      other_key = api_key_fixture(user_fixture())
      conn = authed(build_conn(), other_key)

      assert conn |> get(~p"/api/runs/#{run_id}") |> json_response(404)
      assert conn |> get(~p"/api/runs/#{run_id}/events") |> json_response(404)
      assert conn |> post(~p"/api/runs/#{run_id}/cancel") |> json_response(404)
      assert Runs.get_run!(run_id).status == :queued
    end
  end
end
