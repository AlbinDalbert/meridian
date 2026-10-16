defmodule MeridianWeb.ApiTest do
  use MeridianWeb.ConnCase, async: true
  use Oban.Testing, repo: Meridian.Repo

  import Meridian.Fixtures

  alias Meridian.Runs
  alias Meridian.Runs.Worker

  @moduletag :capture_log

  setup %{conn: conn} do
    user = user_fixture(%{}, %{"model" => "qwen"})
    coder = persona_fixture(user, %{"slug" => "coder"})
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

  describe "threads" do
    test "create, list, show, update, delete", %{conn: conn} do
      thread = create_thread(conn, %{"title" => "Plans"})
      assert thread["persona"] == "meridian/default"
      assert thread["title"] == "Plans"

      assert %{"data" => [%{"id" => id}]} = conn |> get(~p"/api/threads") |> json_response(200)
      assert id == thread["id"]

      assert %{"data" => %{"active_run" => nil}} =
               conn |> get(~p"/api/threads/#{id}") |> json_response(200)

      assert %{"data" => %{"title" => "Renamed", "persona" => "meridian/coder"}} =
               conn
               |> patch(~p"/api/threads/#{id}", %{"title" => "Renamed", "persona" => "coder"})
               |> json_response(200)

      assert conn |> delete(~p"/api/threads/#{id}") |> response(204)
      assert conn |> get(~p"/api/threads/#{id}") |> json_response(404)
    end

    test "accept a persona model id", %{conn: conn} do
      assert %{"persona" => "meridian/coder"} =
               create_thread(conn, %{"persona" => "meridian/coder"})
    end

    test "only use personas the key allows", %{conn: conn, user: user} do
      restricted = api_key_fixture(user, %{"policy" => %{"allowed_personas" => ["default"]}})
      conn = authed(conn, restricted)

      assert %{"error" => %{"code" => "persona_not_found"}} =
               conn |> post(~p"/api/threads", %{"persona" => "coder"}) |> json_response(422)

      assert %{"persona" => "meridian/default"} = create_thread(conn)
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
      assert run["persona"] == "meridian/default"

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
      assert_receive {:upstream_called, server_pid}

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
