defmodule Meridian.ExtensionsTest do
  use Meridian.DataCase, async: true
  use Oban.Testing, repo: Meridian.Repo

  import Meridian.Fixtures

  @moduletag :capture_log

  alias Meridian.{Extensions, Agents, Runs, Threads}
  alias Meridian.Extensions.{Job, Script}
  alias Meridian.Runs.Worker

  # Every hook, doing nothing.
  @observer """
  local M = { description = "Observes.", settings = { mode = "observe" } }
  for _, hook in ipairs({"run_start", "before_run", "context", "before_model_request",
                         "message_end", "run_end", "thread_created", "thread_deleted"}) do
    M[hook] = function() end
  end
  return M
  """

  # Changes every chained value in a recognisable way.
  @modifier """
  local M = { settings = { section = "Test section." } }

  function M.before_run(config, ctx)
    table.insert(config.system_prompt, ctx.settings.section .. " " .. ctx.agent.slug)
    config.params.seed = 1
    return config
  end

  function M.context(messages)
    table.insert(messages, #messages, { role = "user", content = "Injected." })
    return messages
  end

  function M.before_model_request(body)
    body.user = "test"
    return body
  end

  function M.message_end(content)
    table.insert(content, { type = "text", text = " [tested]" })
    return content
  end

  return M
  """

  setup do
    user = user_fixture(%{}, %{"model" => "qwen", "system_prompt" => "Be brief."})
    %{user: user, agent: Agents.get_default_agent(user)}
  end

  defp enable(agent, extensions) do
    {:ok, agent} = Agents.update_agent(agent, %{"extensions" => extensions})
    agent
  end

  # Sends "Hi" on a new thread and runs it against a stubbed reply of "Hello".
  defp run_message(user) do
    thread = thread_fixture(user)
    {_message, run} = message_fixture(thread, "Hi")
    stub_upstream_stream(completion_events(["Hello"]))
    :ok = perform_job(Worker, %{"run_id" => run.id})
    {thread, Runs.get_run!(run.id)}
  end

  # Reports the hook calls of `extension` to the test, as {:hook, hook, result}.
  defp watch_hooks(extension) do
    test_pid = self()
    handler = "watch-#{extension.id}"
    id = extension.id

    :telemetry.attach(
      handler,
      [:meridian, :extensions, :hook],
      fn
        _event, _measurements, %{extension_id: ^id} = meta, _config ->
          send(test_pid, {:hook, meta.hook, meta.result})

        # Other tests' extensions, running at the same time.
        _event, _measurements, _meta, _config ->
          :ok
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp hooks_received do
    receive do
      {:hook, hook, _result} -> [hook | hooks_received()]
    after
      0 -> []
    end
  end

  defp system_prompt_sent do
    assert_received {:upstream_request, %{"messages" => [%{"role" => "system"} = system | _]}}
    system["content"]
  end

  describe "scripts" do
    test "are checked when saved" do
      assert {:error, changeset} =
               Extensions.create_extension(nil, %{"name" => "bad", "source" => "local x = = 1"})

      assert errors_on(changeset).source == ["line 1: Expected expression"]

      for {source, error} <- [
            {"", "the script must end by returning its table, e.g. `return M`"},
            {"return 42",
             "the script must return a table (its extension), but it returned a number"},
            {"return { before_run = 1 }", "before_run must be a function, not a number"},
            {"return { model_stream_event = function() end }",
             "model_stream_event isn't available to extensions"},
            {"return { settings = { 1, 2 } }",
             "settings must be a table of setting names and their default values"},
            {"error('nope')", "Lua runtime error: nope (at bad.lua:1)"}
          ] do
        assert {:error, changeset} =
                 Extensions.create_extension(nil, %{"name" => "bad", "source" => source})

        assert errors_on(changeset).source == [error]
      end
    end

    test "can't loop forever or reach the host while loading" do
      assert {:error, changeset} =
               Extensions.create_extension(nil, %{"name" => "x", "source" => "while true do end"})

      assert [error] = errors_on(changeset).source
      assert error =~ "instruction budget exceeded"

      assert {:error, changeset} =
               Extensions.create_extension(nil, %{
                 "name" => "x",
                 "source" => ~s[os.execute("ls") return {}]
               })

      assert [error] = errors_on(changeset).source
      assert error =~ "sandboxed"

      assert {:error, changeset} =
               Extensions.create_extension(nil, %{
                 "name" => "x",
                 "source" => "meridian.now() return {}"
               })

      assert errors_on(changeset).source == [
               "Lua runtime error: meridian.now can only be called from a hook or a job"
             ]
    end

    test "describe the extension" do
      {:ok, script} = Script.load(@observer)
      assert script.description == "Observes."
      assert script.settings == %{"mode" => "observe"}
      assert "run_start" in script.hooks and "thread_deleted" in script.hooks

      {:ok, script} = Script.load("return {}")
      assert %{description: "", settings: %{}, hooks: [], jobs: []} = script
    end

    test "names are unique among global extensions and among each user's own", %{user: user} do
      extension_fixture(nil, "return {}", %{"name" => "same"})
      mine = extension_fixture(user, "return {}", %{"name" => "same"})

      assert {:error, changeset} =
               Extensions.create_extension(nil, %{"name" => "same", "source" => "return {}"})

      assert errors_on(changeset).name == ["has already been taken"]

      assert {:error, changeset} =
               Extensions.create_extension(user, %{"name" => "same", "source" => "return {}"})

      assert errors_on(changeset).name == ["has already been taken"]
      assert mine.user_id == user.id
    end

    test "users can use global extensions and their own", %{user: user} do
      global = extension_fixture(nil, "return {}")
      mine = extension_fixture(user, "return {}")
      theirs = extension_fixture(user_fixture(), "return {}")

      ids = user |> Extensions.list_available() |> Enum.map(& &1.id)
      assert global.id in ids and mine.id in ids
      refute theirs.id in ids

      assert Extensions.get_available_extension!(user, global.id)

      assert_raise Ecto.NoResultsError, fn ->
        Extensions.get_available_extension!(user, theirs.id)
      end
    end
  end

  describe "enablement" do
    test "extensions only run for agents that enable them", %{user: user} do
      extension = extension_fixture(nil, @observer)
      watch_hooks(extension)
      {_thread, run} = run_message(user)
      assert run.status == :completed
      assert hooks_received() == []
    end

    test "an enabled extension's hooks are called in lifecycle order", %{
      user: user,
      agent: agent
    } do
      extension = extension_fixture(nil, @observer)
      watch_hooks(extension)
      enable(agent, %{extension.id => %{}})
      {thread, run} = run_message(user)
      assert run.status == :completed

      assert hooks_received() ==
               ~w(thread_created run_start before_run context before_model_request message_end
                  run_end)

      Threads.delete_thread(thread)
      assert_received {:hook, "thread_deleted", :ok}
    end

    test "hooks get the run's context and the agent's settings", %{user: user, agent: agent} do
      extension =
        extension_fixture(user, """
        return {
          settings = { greeting = "Hello" },
          before_run = function(config, ctx)
            table.insert(config.system_prompt, table.concat({ctx.settings.greeting,
              ctx.agent.slug, ctx.agent.model, tostring(ctx.user_id == ctx.agent.id),
              tostring(ctx.run_id ~= nil), tostring(ctx.thread_id ~= nil)}, " "))
            return config
          end,
        }
        """)

      enable(agent, %{extension.id => %{"greeting" => "Hey"}})
      run_message(user)
      assert system_prompt_sent() == "Be brief.\n\nHey default qwen false true true"
    end

    test "settings are frozen into the run", %{user: user, agent: agent} do
      extension = extension_fixture(nil, @modifier)
      agent = enable(agent, %{extension.id => %{}})
      thread = thread_fixture(user)
      {_message, run} = message_fixture(thread)

      enable(agent, %{})
      stub_upstream_stream(completion_events(["ok"]))
      :ok = perform_job(Worker, %{"run_id" => run.id})
      assert system_prompt_sent() == "Be brief.\n\nTest section. default"
    end

    test "a saved script is used from the next call on", %{user: user, agent: agent} do
      extension = extension_fixture(nil, @modifier)
      enable(agent, %{extension.id => %{}})
      run_message(user)
      assert system_prompt_sent() =~ "Test section."

      {:ok, _extension} =
        Extensions.update_extension(extension, %{
          "source" => String.replace(@modifier, "Test section.", "New section.")
        })

      run_message(user)
      assert system_prompt_sent() =~ "New section."
    end

    test "extensions run in name order", %{user: user, agent: agent} do
      b = extension_fixture(nil, section_script("B"), %{"name" => "b-ext"})
      a = extension_fixture(nil, section_script("A"), %{"name" => "a-ext"})
      enable(agent, %{b.id => %{}, a.id => %{}})
      run_message(user)
      assert system_prompt_sent() == "Be brief.\n\nA\n\nB"
    end

    test "entries for extensions that are gone, or someone else's, are kept and ignored", %{
      user: user,
      agent: agent
    } do
      gone = extension_fixture(nil, @modifier)
      theirs = extension_fixture(user_fixture(), @modifier)
      agent = enable(agent, %{gone.id => %{"x" => 1}, theirs.id => %{}})
      {:ok, _} = Extensions.delete_extension(gone)

      assert Map.keys(agent.extensions) |> Enum.sort() == Enum.sort([gone.id, theirs.id])
      assert Extensions.enabled(Agents.get_agent!(agent.id)) == []
      run_message(user)
      assert system_prompt_sent() == "Be brief."
    end

    test "settings are validated", %{agent: agent} do
      extension =
        extension_fixture(nil, """
        return {
          settings = { mode = "observe" },
          validate = function(settings)
            if settings.mode ~= "observe" then return "unknown mode" end
          end,
        }
        """)

      name = extension.name
      assert enable(agent, %{extension.id => %{"mode" => "observe"}})

      assert {:error, changeset} =
               Agents.update_agent(agent, %{
                 "extensions" => %{extension.id => %{"mode" => "?"}}
               })

      assert errors_on(changeset).extensions == ["#{name}: unknown mode"]

      assert {:error, changeset} =
               Agents.update_agent(agent, %{"extensions" => %{extension.id => "on"}})

      assert errors_on(changeset).extensions == ["#{name}: settings must be a JSON object"]
    end
  end

  defp section_script(text) do
    """
    return {
      before_run = function(config)
        table.insert(config.system_prompt, "#{text}")
        return config
      end,
    }
    """
  end

  describe "chained hooks" do
    test "change the request and the saved reply", %{user: user, agent: agent} do
      extension = extension_fixture(nil, @modifier)
      enable(agent, %{extension.id => %{}})
      {thread, _run} = run_message(user)

      assert_received {:upstream_request, body}
      assert body["seed"] == 1
      assert body["user"] == "test"

      assert body["messages"] == [
               %{"role" => "system", "content" => "Be brief.\n\nTest section. default"},
               %{"role" => "user", "content" => "Injected."},
               %{"role" => "user", "content" => "Hi"}
             ]

      assert [_user, reply] = Threads.list_all_messages(thread)
      assert Threads.Message.text(reply) == "Hello [tested]"
    end

    for {mode, source} <- [
          crash: "error('crashed')",
          slow: "while true do end",
          invalid: "return 42",
          sandboxed: "os.exit(1)"
        ] do
      test "a handler that is #{mode} is skipped, and its error kept", %{
        user: user,
        agent: agent
      } do
        extension =
          extension_fixture(nil, """
          local function handler() #{unquote(source)} end
          return { before_run = handler, context = handler, message_end = handler }
          """)

        enable(agent, %{extension.id => %{}})
        {thread, run} = run_message(user)
        assert run.status == :completed

        assert_received {:upstream_request, body}

        assert body["messages"] == [
                 %{"role" => "system", "content" => "Be brief."},
                 %{"role" => "user", "content" => "Hi"}
               ]

        assert [_user, reply] = Threads.list_all_messages(thread)
        assert Threads.Message.text(reply) == "Hello"
        assert %{where: "message_end", message: message} = Extensions.last_error(extension)
        assert is_binary(message)
      end
    end

    test "before_run can reject a run", %{user: user, agent: agent} do
      extension =
        extension_fixture(nil, """
        return { before_run = function() return false, "not today" end }
        """)

      enable(agent, %{extension.id => %{}})
      {_thread, run} = run_message(user)

      assert run.status == :failed
      assert run.error == %{"code" => "rejected", "message" => "not today"}
      refute_received {:upstream_request, _body}
    end

    test "other hooks can't halt", %{user: user, agent: agent} do
      extension =
        extension_fixture(nil, """
        return { context = function() return false, "not today" end }
        """)

      enable(agent, %{extension.id => %{}})
      {_thread, run} = run_message(user)
      assert run.status == :completed
    end
  end

  describe "run_end" do
    test "fires for runs that fail, and for cancelled queued runs", %{
      user: user,
      agent: agent
    } do
      extension = extension_fixture(nil, @observer)
      watch_hooks(extension)
      enable(agent, %{extension.id => %{}})

      thread = thread_fixture(user)
      {_message, run} = message_fixture(thread)
      stub_upstream_down()
      :ok = perform_job(Worker, %{"run_id" => run.id})
      assert_received {:hook, "run_end", :ok}

      {_message, run} = message_fixture(thread)
      {:ok, _run} = Runs.cancel_run(run)
      assert_received {:hook, "run_end", :ok}
    end
  end

  # A title extension, much like the one that used to be built in.
  @title """
  local M = { settings = { model = false } }

  function M.run_end(run, ctx)
    if run.status ~= "completed" then return end
    local thread = meridian.threads.get(run.thread_id)
    if thread and thread.title == nil then
      meridian.jobs.enqueue("name_thread",
        { thread_id = run.thread_id, model = ctx.settings.model or ctx.agent.model },
        { unique = run.thread_id })
    end
  end

  M.jobs = {}

  function M.jobs.name_thread(args, ctx)
    local messages = meridian.threads.messages(args.thread_id)
    local text = assert(meridian.model.complete({
      model = args.model,
      messages = {
        { role = "system", content = "Name this conversation." },
        { role = "user", content = messages[1].text },
      },
    }))
    meridian.threads.set_title(args.thread_id, (text:gsub('"', "")), { only_if_untitled = true })
  end

  return M
  """

  describe "jobs and capabilities" do
    defp stub_completion(content) do
      test_pid = self()

      Req.Test.stub(Meridian.Upstream, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:completion_request, Jason.decode!(body)})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}]
        })
      end)
    end

    test "a hook queues a job that calls the model and names the thread", %{
      user: user,
      agent: agent
    } do
      extension = extension_fixture(nil, @title)
      enable(agent, %{extension.id => %{}})
      {thread, _run} = run_message(user)

      assert [job] = all_enqueued(worker: Job)
      assert job.args["job"] == "name_thread"
      assert job.args["args"] == %{"thread_id" => thread.id, "model" => "qwen"}

      stub_completion(~s("Greetings"))
      assert :ok = perform_job(Job, job.args)

      assert_received {:completion_request, %{"model" => "qwen", "messages" => [_, user_message]}}
      assert user_message["content"] == "Hi"
      assert Threads.get_thread!(thread.id).title == "Greetings"
    end

    test "unique jobs aren't queued twice", %{user: user, agent: agent} do
      extension = extension_fixture(nil, @title)
      enable(agent, %{extension.id => %{}})
      thread = thread_fixture(user)

      for _ <- 1..2 do
        {_message, run} = message_fixture(thread)
        stub_upstream_stream(completion_events(["ok"]))
        :ok = perform_job(Worker, %{"run_id" => run.id})
      end

      assert [_job] = all_enqueued(worker: Job)
    end

    test "jobs whose extension or function is gone are cancelled", %{user: user} do
      extension = extension_fixture(nil, @title)
      ctx = %{"user_id" => user.id, "agent" => %{}}
      args = %{"extension_id" => extension.id, "job" => "nope", "args" => %{}, "ctx" => ctx}
      assert {:cancel, _} = perform_job(Job, args)

      {:ok, _} = Extensions.delete_extension(extension)
      assert {:cancel, _} = perform_job(Job, %{args | "job" => "name_thread"})
    end

    test "only reach the user's own threads", %{user: user, agent: agent} do
      theirs = thread_fixture(user_fixture(), %{"title" => "Secret"})

      extension =
        extension_fixture(nil, """
        return {
          before_run = function(config, ctx)
            local mine = meridian.threads.get(ctx.thread_id)
            local other = meridian.threads.get("#{theirs.id}")
            local ok, err = meridian.threads.set_title("#{theirs.id}", "Hacked")
            table.insert(config.system_prompt, table.concat({tostring(mine.id == ctx.thread_id),
              tostring(other), tostring(ok), err, tostring(meridian.threads.messages("x"))}, " "))
            return config
          end,
        }
        """)

      enable(agent, %{extension.id => %{}})
      run_message(user)
      assert system_prompt_sent() == "Be brief.\n\ntrue nil nil not_found nil"
      assert Threads.get_thread!(theirs.id).title == "Secret"
    end

    test "time and JSON", %{user: user, agent: agent} do
      extension =
        extension_fixture(nil, """
        return {
          before_run = function(config)
            local data = meridian.json.decode('{"a": [1, 2]}')
            local _, err = meridian.now("Mars/Olympus")
            table.insert(config.system_prompt, table.concat({meridian.now("Europe/Stockholm",
              "%Y"), meridian.json.encode(data.a), err}, " "))
            return config
          end,
        }
        """)

      enable(agent, %{extension.id => %{}})
      run_message(user)
      year = DateTime.now!("Europe/Stockholm").year

      assert system_prompt_sent() ==
               ~s(Be brief.\n\n#{year} [1,2] unknown timezone "Mars/Olympus")
    end
  end
end
