defmodule Meridian.ToolsTest do
  use Meridian.DataCase, async: true
  use Oban.Testing, repo: Meridian.Repo

  import Meridian.Fixtures

  @moduletag :capture_log

  alias Meridian.{Extensions, Personas, Runs, Threads}
  alias Meridian.Runs.Worker
  alias Meridian.Threads.Message

  @weather """
  local M = { settings = { units = "metric", offer = true } }

  local function weather(city, units)
    return city .. ": rain (" .. units .. ")"
  end

  M.tools = {
    get_weather = {
      description = "Current weather for a city",
      parameters = { type = "object", properties = { city = { type = "string" } },
                     required = { "city" } },
      run = function(args, ctx) return weather(args.city, ctx.settings.units) end,
    },
    report = { description = "Returns a table", run = function() return { ok = true } end },
    fails = { description = "Fails", run = function() return nil, "no such city" end },
    raises = { description = "Raises", run = function() error("boom") end },
  }

  function M.before_run(config, ctx)
    if not ctx.settings.offer then config.tools = {} end
    return config
  end

  return M
  """

  setup do
    user = user_fixture(%{}, %{"model" => "qwen"})
    persona = Personas.get_default_persona(user)
    weather = extension_fixture(nil, @weather)
    {:ok, persona} = Personas.update_persona(persona, %{"extensions" => %{weather.id => %{}}})
    %{user: user, persona: persona, weather: weather, tool: weather.name <> "__get_weather"}
  end

  # Sends "Hi" on a new thread and runs it, the upstream answering with `responses` in turn.
  defp run_message(user, responses) do
    thread = thread_fixture(user)
    {_message, run} = message_fixture(thread, "Hi")
    stub_upstream_streams(responses)
    :ok = perform_job(Worker, %{"run_id" => run.id})
    {thread, Runs.get_run!(run.id)}
  end

  defp requests do
    receive do
      {:upstream_request, body} -> [body | requests()]
    after
      0 -> []
    end
  end

  defp tool_results(request) do
    for %{"role" => "tool"} = message <- request["messages"],
        do: {message["tool_call_id"], message["content"]}
  end

  describe "scripts" do
    test "declare tools, checked when saved", %{weather: weather} do
      assert {:ok, script} = Extensions.script(weather)
      assert Map.keys(script.tools) == ~w(fails get_weather raises report)

      assert script.tools["get_weather"].parameters == %{
               "type" => "object",
               "properties" => %{"city" => %{"type" => "string"}},
               "required" => ["city"]
             }

      # No parameters: the tool takes no arguments. JSON text works too.
      assert script.tools["report"].parameters == %{"type" => "object", "properties" => %{}}

      assert {:ok, _} =
               Extensions.create_extension(nil, %{
                 "name" => unique_name("json"),
                 "source" => """
                 return { tools = { t = { description = "T", run = function() end,
                   parameters = [[{"type": "object", "properties": {}, "required": []}]] } } }
                 """
               })

      for {source, error} <- [
            {"return { tools = 1 }", "tools must be a table, not a number"},
            {"return { tools = { 1 } }",
             "tools must be a table of tool names and their definitions"},
            {"return { tools = { t = 1 } }", "tools.t must be a table, not a number"},
            {"return { tools = { t = { description = 'T' } } }", "tools.t.run is missing"},
            {"return { tools = { t = { run = function() end } } }",
             "tools.t.description is missing"},
            {"return { tools = { ['a b'] = { description = 'T', run = function() end } } }",
             ~s(tool names may only have letters, digits, '_' and '-': "a b")},
            {"return { tools = { t = { description = 'T', run = function() end, " <>
               "parameters = { type = 'string' } } } }",
             ~s(tools.t.parameters must be a JSON Schema with type "object")},
            {"return { tools = { t = { description = 'T', run = function() end, " <>
               "parameters = '{' } } }", "tools.t.parameters isn't valid JSON"}
          ] do
        assert {:error, changeset} =
                 Extensions.create_extension(nil, %{"name" => "bad", "source" => source})

        assert errors_on(changeset).source == [error]
      end
    end

    test "tool names are unique per run, and fit upstream limits", %{user: user} do
      long = String.duplicate("a", 60)

      global =
        extension_fixture(
          nil,
          "return { tools = { t = { description = 'T', run = function() end } } }",
          %{"name" => long}
        )

      own =
        extension_fixture(
          user,
          "return { tools = { t = { description = 'T', run = function() end } } }",
          %{"name" => long}
        )

      {:ok, persona} =
        user
        |> Personas.get_default_persona()
        |> Personas.update_persona(%{"extensions" => %{global.id => %{}, own.id => %{}}})

      names = persona |> Extensions.enabled() |> Extensions.tool_set() |> Enum.map(& &1.name)
      assert length(Enum.uniq(names)) == 2
      assert Enum.all?(names, &Regex.match?(~r/^[a-zA-Z0-9_-]{1,64}$/, &1))
    end
  end

  describe "the tool loop" do
    test "runs the tools the model asks for and continues with the results",
         %{user: user, tool: tool} do
      {thread, run} =
        run_message(user, [
          tool_call_events([{"call_1", tool, ~s({"city": "Oslo"})}], ["Let me check."]),
          completion_events(["Bring an umbrella."])
        ])

      assert run.status == :completed
      # Usage of both model calls.
      assert run.usage["total_tokens"] == 14

      assert [first, second] = requests()

      assert %{"type" => "function", "function" => %{"name" => ^tool} = definition} =
               Enum.find(first["tools"], &(&1["function"]["name"] == tool))

      assert definition["description"] == "Current weather for a city"
      assert length(first["tools"]) == 4
      assert second["tools"] == first["tools"]

      assert Enum.map(second["messages"], & &1["role"]) == ~w(user assistant tool)
      assert [_user, assistant, _tool] = second["messages"]
      assert assistant["content"] == "Let me check."

      assert assistant["tool_calls"] == [
               %{
                 "id" => "call_1",
                 "type" => "function",
                 "function" => %{"name" => tool, "arguments" => ~s({"city": "Oslo"})}
               }
             ]

      assert tool_results(second) == [{"call_1", "Oslo: rain (metric)"}]

      assert [_user, asked, result, reply] = Threads.list_all_messages(thread)
      assert asked.role == "assistant" and asked.run_id == run.id
      assert asked.metadata == %{"finish_reason" => "tool_calls"}
      assert result.role == "tool" and result.tool_call_id == "call_1"
      assert result.metadata == %{"status" => "ok"}
      assert reply.content == [%{"type" => "text", "text" => "Bring an umbrella."}]

      events = Runs.list_events(run)
      assert Enum.map(events, & &1.seq) == Enum.to_list(1..length(events))

      assert Enum.map(events, & &1.type) ==
               ~w(run.started message.delta message.completed tool_call.started
                  tool_call.completed message.delta message.completed run.completed)

      started = Enum.find(events, &(&1.type == "tool_call.started"))

      assert started.payload == %{
               "id" => "call_1",
               "name" => tool,
               "arguments" => ~s({"city": "Oslo"})
             }

      completed = Enum.find(events, &(&1.type == "tool_call.completed"))
      assert completed.payload["status"] == "ok"

      assert completed.payload["message"]["content"] == [
               %{"type" => "text", "text" => "Oslo: rain (metric)"}
             ]

      # A later run sends the whole exchange again.
      {_message, next} = message_fixture(thread, "Thanks")
      :ok = perform_job(Worker, %{"run_id" => next.id})
      assert [%{"messages" => messages}] = requests()
      assert Enum.map(messages, & &1["role"]) == ~w(user assistant tool assistant user)
    end

    test "turns every kind of tool failure into a result for the model",
         %{user: user, weather: weather, tool: tool} do
      name = &(weather.name <> "__" <> &1)

      {_thread, run} =
        run_message(user, [
          tool_call_events([
            {"c1", tool, ~s({"city": "Bergen"})},
            {"c2", name.("report"), ""},
            {"c3", name.("fails"), "{}"},
            {"c4", name.("raises"), "{}"},
            {"c5", "nope", "{}"},
            {"c6", tool, "not json"},
            {"c7", tool, "[1]"}
          ]),
          completion_events(["Done."])
        ])

      assert run.status == :completed
      assert [_first, second] = requests()

      assert [
               {"c1", "Bergen: rain (metric)"},
               {"c2", ~s({"ok":true})},
               {"c3", "Error: no such city"},
               {"c4", "Error: " <> raised},
               {"c5", ~s(Error: there is no tool named "nope".)},
               {"c6", "Error: the arguments must be a JSON object."},
               {"c7", "Error: the arguments must be a JSON object."}
             ] = tool_results(second)

      assert raised =~ "boom"
      assert Extensions.last_error(weather).where == "tools.raises"
    end

    test "settings reach tools, and before_run can drop them", %{
      user: user,
      persona: persona,
      weather: weather,
      tool: tool
    } do
      {:ok, _} =
        Personas.update_persona(persona, %{
          "extensions" => %{weather.id => %{"units" => "imperial"}}
        })

      run_message(user, [
        tool_call_events([{"c1", tool, ~s({"city": "Oslo"})}]),
        completion_events(["ok"])
      ])

      assert [_first, second] = requests()
      assert tool_results(second) == [{"c1", "Oslo: rain (imperial)"}]

      {:ok, _} =
        Personas.update_persona(persona, %{"extensions" => %{weather.id => %{"offer" => false}}})

      run_message(user, [completion_events(["ok"])])
      assert [request] = requests()
      refute Map.has_key?(request, "tools")
    end

    test "tool_call can rewrite or block calls, tool_result can change results",
         %{user: user, persona: persona, weather: weather, tool: tool} do
      guard =
        extension_fixture(nil, """
        local M = {}

        function M.tool_call(call)
          if call.arguments.city == "Mordor" then return false, "not there" end
          call.arguments.city = string.upper(call.arguments.city)
          return call
        end

        function M.tool_result(result)
          result.content = result.content .. " [checked " .. result.status .. "]"
          return result
        end

        return M
        """)

      {:ok, _} =
        Personas.update_persona(persona, %{
          "extensions" => %{weather.id => %{}, guard.id => %{}}
        })

      run_message(user, [
        tool_call_events([
          {"c1", tool, ~s({"city": "oslo"})},
          {"c2", tool, ~s({"city": "Mordor"})}
        ]),
        completion_events(["ok"])
      ])

      assert [_first, second] = requests()

      assert tool_results(second) == [
               {"c1", "OSLO: rain (metric) [checked ok]"},
               {"c2", "Error: the call was blocked: not there [checked error]"}
             ]
    end

    test "a failing tool_call handler blocks the call", %{
      user: user,
      persona: persona,
      weather: weather,
      tool: tool
    } do
      guard = extension_fixture(nil, "return { tool_call = function() error('broken') end }")

      {:ok, _} =
        Personas.update_persona(persona, %{
          "extensions" => %{weather.id => %{}, guard.id => %{}}
        })

      run_message(user, [
        tool_call_events([{"c1", tool, ~s({"city": "Oslo"})}]),
        completion_events(["ok"])
      ])

      assert [_first, second] = requests()

      assert [{"c1", "Error: the call was blocked: " <> _}] = tool_results(second)
      assert Extensions.last_error(guard).where == "tool_call"
    end

    test "step_end fires after every step", %{
      user: user,
      persona: persona,
      weather: weather,
      tool: tool
    } do
      observer =
        extension_fixture(nil, """
        return { step_end = function(step) meridian.log("step", step.index, step.finish_reason) end }
        """)

      {:ok, _} =
        Personas.update_persona(persona, %{
          "extensions" => %{weather.id => %{}, observer.id => %{}}
        })

      test_pid = self()
      id = observer.id

      :telemetry.attach(
        "steps-#{id}",
        [:meridian, :extensions, :hook],
        fn
          _, _, %{extension_id: ^id, hook: hook}, _ -> send(test_pid, {:hook, hook})
          _, _, _, _ -> :ok
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("steps-#{id}") end)

      run_message(user, [
        tool_call_events([{"c1", tool, ~s({"city": "Oslo"})}]),
        completion_events(["ok"])
      ])

      assert_received {:hook, "step_end"}
      assert_received {:hook, "step_end"}
      refute_received {:hook, "step_end"}
    end

    test "a model that keeps calling tools fails the run", %{user: user, tool: tool} do
      {_thread, run} = run_message(user, [tool_call_events([{"c", tool, ~s({"city": "Oslo"})}])])

      assert run.status == :failed
      assert run.error["code"] == "too_many_steps"
      assert length(requests()) == 10
    end

    test "cancelling stops a running tool call", %{user: user, persona: persona} do
      # A tool that waits on the model, which never answers.
      slow =
        extension_fixture(nil, """
        return { tools = { wait = { description = "Waits",
          run = function() return meridian.model.complete({ messages = {} }) end } } }
        """)

      {:ok, _} = Personas.update_persona(persona, %{"extensions" => %{slow.id => %{}}})
      wait = slow.name <> "__wait"
      thread = thread_fixture(user)
      {_message, run} = message_fixture(thread, "Hi")
      test_pid = self()
      events = tool_call_events([{"c1", wait, "{}"}])

      Req.Test.stub(Meridian.Upstream, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        if Jason.decode!(body)["stream"] do
          conn =
            conn
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_chunked(200)

          Enum.reduce(events, conn, fn event, conn ->
            {:ok, conn} = Plug.Conn.chunk(conn, event)
            conn
          end)
        else
          send(test_pid, {:tool_waiting, self()})

          receive do
            :never -> conn
          end
        end
      end)

      task = Task.async(fn -> perform_job(Worker, %{"run_id" => run.id}) end)
      assert_receive {:tool_waiting, tool_pid}, 2000
      tool_ref = Process.monitor(tool_pid)

      assert {:ok, _} = Runs.cancel_run(Runs.get_run!(run.id))
      assert :ok = Task.await(task)
      assert_receive {:DOWN, ^tool_ref, :process, ^tool_pid, _reason}

      assert Runs.get_run!(run.id).status == :cancelled

      assert Runs.list_events(run) |> Enum.map(& &1.type) ==
               ~w(run.started message.completed tool_call.started run.cancelled)

      # The call never got a result; the history says so.
      assert [_user, asked] = messages = Threads.list_all_messages(thread)
      assert asked.tool_calls != nil

      assert [_, _, %{"role" => "tool", "tool_call_id" => "c1", "content" => interrupted}] =
               Message.to_upstream_history(messages)

      assert interrupted =~ "interrupted"
    end
  end
end
