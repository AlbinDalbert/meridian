defmodule Meridian.ExtensionsTest do
  use Meridian.DataCase, async: true
  use Oban.Testing, repo: Meridian.Repo

  import Meridian.Fixtures

  @moduletag :capture_log

  alias Meridian.{Extensions, Personas, Runs, Threads, TestExtension}
  alias Meridian.Extension.Context
  alias Meridian.Runs.Worker

  setup do
    user = user_fixture(%{}, %{"model" => "qwen", "system_prompt" => "Be brief."})
    %{user: user, persona: Personas.get_default_persona(user)}
  end

  defp enable(persona, extensions) do
    {:ok, persona} = Personas.update_persona(persona, %{"extensions" => extensions})
    persona
  end

  # Sends "Hi" on a new thread and runs it against a stubbed reply of "Hello".
  defp run_message(user) do
    thread = thread_fixture(user)
    {_message, run} = message_fixture(thread, "Hi")
    stub_upstream_stream(completion_events(["Hello"]))
    :ok = perform_job(Worker, %{"run_id" => run.id})
    {thread, Runs.get_run!(run.id)}
  end

  defp hooks_received do
    receive do
      {:hook, hook, _value, _ctx} -> [hook | hooks_received()]
    after
      0 -> []
    end
  end

  describe "enablement" do
    test "extensions only run for personas that enable them", %{user: user} do
      {_thread, run} = run_message(user)
      assert run.status == :completed
      refute_received {:hook, _hook, _value, _ctx}
    end

    test "an enabled extension's hooks are called in lifecycle order", %{
      user: user,
      persona: persona
    } do
      enable(persona, TestExtension.enable())
      {thread, run} = run_message(user)
      assert run.status == :completed

      assert hooks_received() == [
               :thread_created,
               :run_start,
               :before_run,
               :context,
               :before_model_request,
               # One per upstream chunk: the delta, the finish reason, and the usage.
               :model_stream_event,
               :model_stream_event,
               :model_stream_event,
               :message_end,
               :run_end
             ]

      Threads.delete_thread(thread)
      assert_received {:hook, :thread_deleted, %{id: thread_id}, _ctx}
      assert thread_id == thread.id
    end

    test "hooks get the run's context and the persona's settings", %{user: user, persona: persona} do
      enable(persona, TestExtension.enable())
      {thread, run} = run_message(user)

      assert_received {:hook, :run_end, %{status: :completed}, %Context{} = ctx}
      assert ctx.run_id == run.id
      assert ctx.thread_id == thread.id
      assert ctx.user_id == user.id
      assert ctx.persona.slug == "default"
      assert ctx.settings["mode"] == "observe"
    end

    test "settings are frozen into the run", %{persona: persona} do
      persona = enable(persona, TestExtension.enable())
      thread = thread_fixture(%Meridian.Accounts.User{id: persona.user_id})
      {_message, run} = message_fixture(thread)

      enable(persona, %{})
      stub_upstream_stream(completion_events(["ok"]))
      :ok = perform_job(Worker, %{"run_id" => run.id})
      assert_received {:hook, :run_start, _value, _ctx}
    end

    test "extensions run in priority order, then installation order" do
      # Datetime and the test extension both have the default priority.
      persona = %Personas.Persona{extensions: %{"test" => %{}, "datetime" => %{}}}
      assert [{Meridian.Ext.Datetime, _}, {TestExtension, _}] = Extensions.enabled(persona)
    end

    test "entries for extensions that aren't installed are kept and ignored", %{persona: persona} do
      persona = enable(persona, %{"gone" => %{"x" => 1}})
      assert persona.extensions == %{"gone" => %{"x" => 1}}
      assert Extensions.enabled(persona) == []
    end

    test "settings are validated", %{persona: persona} do
      assert {:error, changeset} =
               Personas.update_persona(persona, %{"extensions" => %{"test" => %{"mode" => "?"}}})

      assert errors_on(changeset).extensions == ["test: unknown mode"]

      assert {:error, changeset} =
               Personas.update_persona(persona, %{"extensions" => %{"test" => "on"}})

      assert errors_on(changeset).extensions == ["test: settings must be a JSON object"]
    end
  end

  describe "chained hooks" do
    test "change the request and the saved reply", %{user: user, persona: persona} do
      enable(persona, TestExtension.enable("modify"))
      {thread, _run} = run_message(user)

      assert_received {:upstream_request, body}
      assert body["seed"] == 1
      assert body["user"] == "test"

      assert body["messages"] == [
               %{"role" => "system", "content" => "Be brief.\n\nTest section."},
               %{"role" => "user", "content" => "Injected."},
               %{"role" => "user", "content" => "Hi"}
             ]

      assert [_user, reply] = Threads.list_all_messages(thread)
      assert Threads.Message.text(reply) == "Hello [tested]"
    end

    for mode <- ~w(crash slow invalid) do
      test "a handler that is #{mode} is skipped", %{user: user, persona: persona} do
        enable(persona, TestExtension.enable(unquote(mode)))
        {thread, run} = run_message(user)
        assert run.status == :completed

        assert_received {:upstream_request, body}

        assert body["messages"] == [
                 %{"role" => "system", "content" => "Be brief."},
                 %{"role" => "user", "content" => "Hi"}
               ]

        assert [_user, reply] = Threads.list_all_messages(thread)
        assert Threads.Message.text(reply) == "Hello"
      end
    end

    test "before_run can reject a run", %{user: user, persona: persona} do
      enable(persona, TestExtension.enable("halt", ["before_run"]))
      {_thread, run} = run_message(user)

      assert run.status == :failed
      assert run.error == %{"code" => "rejected", "message" => "halted in before_run"}
      refute_received {:upstream_request, _body}
      assert_received {:hook, :run_end, %{status: :failed}, _ctx}
    end

    test "other hooks can't halt", %{user: user, persona: persona} do
      enable(persona, TestExtension.enable("halt", ["context"]))
      {_thread, run} = run_message(user)
      assert run.status == :completed
    end
  end

  describe "run_end" do
    test "fires for runs that fail", %{user: user, persona: persona} do
      enable(persona, TestExtension.enable())
      thread = thread_fixture(user)
      {_message, run} = message_fixture(thread)
      stub_upstream_down()
      :ok = perform_job(Worker, %{"run_id" => run.id})

      assert_received {:hook, :run_end, %{status: :failed}, _ctx}
    end

    test "fires when a queued run is cancelled", %{user: user, persona: persona} do
      enable(persona, TestExtension.enable())
      thread = thread_fixture(user)
      {_message, run} = message_fixture(thread)
      {:ok, _run} = Runs.cancel_run(run)

      assert_received {:hook, :run_end, %{status: :cancelled}, _ctx}
      refute_received {:hook, :run_start, _value, _ctx}
    end
  end

  describe "datetime" do
    test "adds the date and time in the persona's timezone", %{user: user, persona: persona} do
      enable(persona, %{"datetime" => %{"timezone" => "Europe/Stockholm"}})
      run_message(user)

      assert_received {:upstream_request, %{"messages" => [system | _rest]}}

      assert system["content"] =~
               ~r/^Be brief\.\n\nThe current date and time is \w+day, \d{1,2} \w+ \d{4}, \d\d:\d\d \(Europe\/Stockholm, UTC\+0[12]00\)\.$/
    end

    test "formats the date" do
      {:ok, now} = DateTime.new(~D[2026-07-04], ~T[09:05:00], "Europe/Stockholm")

      assert Meridian.Ext.Datetime.section(now, "Europe/Stockholm") ==
               "The current date and time is Saturday, 4 July 2026, 09:05 (Europe/Stockholm, UTC+0200)."
    end

    test "defaults to UTC and rejects unknown timezones", %{persona: persona} do
      assert Extensions.enabled(enable(persona, %{"datetime" => %{}})) ==
               [{Meridian.Ext.Datetime, %{"timezone" => "Etc/UTC"}}]

      assert {:error, changeset} =
               Personas.update_persona(persona, %{
                 "extensions" => %{"datetime" => %{"timezone" => "Mars/Olympus"}}
               })

      assert errors_on(changeset).extensions == [~s(datetime: unknown timezone "Mars/Olympus")]
    end
  end

  describe "title" do
    alias Meridian.Ext.Title.Worker, as: TitleWorker

    defp stub_title(content) do
      test_pid = self()

      Req.Test.stub(Meridian.Upstream, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:title_request, Jason.decode!(body)})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}]
        })
      end)
    end

    test "names an untitled thread after its first reply", %{user: user, persona: persona} do
      enable(persona, %{"title" => %{}})
      {thread, _run} = run_message(user)

      assert_enqueued(worker: TitleWorker, args: %{thread_id: thread.id, model: "qwen"})

      stub_title(~s("Greeting exchange."))
      assert :ok = perform_job(TitleWorker, %{"thread_id" => thread.id, "model" => "qwen"})

      assert_received {:title_request, %{"model" => "qwen", "stream" => false} = request}
      assert [_system, %{"content" => "User: Hi\n\nAssistant: Hello"}] = request["messages"]
      assert Threads.get_thread!(thread.id).title == "Greeting exchange"
    end

    test "uses the model from its settings", %{user: user, persona: persona} do
      enable(persona, %{"title" => %{"model" => "small"}})
      {thread, _run} = run_message(user)
      assert_enqueued(worker: TitleWorker, args: %{thread_id: thread.id, model: "small"})
    end

    test "leaves titled threads alone", %{user: user, persona: persona} do
      enable(persona, %{"title" => %{}})
      thread = thread_fixture(user, %{"title" => "Mine"})
      {_message, run} = message_fixture(thread)
      stub_upstream_stream(completion_events(["ok"]))
      :ok = perform_job(Worker, %{"run_id" => run.id})

      refute_enqueued(worker: TitleWorker)
    end

    test "doesn't overwrite a title set while it ran", %{user: user, persona: persona} do
      enable(persona, %{"title" => %{}})
      {thread, _run} = run_message(user)
      :ok = Threads.set_title(thread.id, "Mine")

      stub_title("Model title")
      assert :ok = perform_job(TitleWorker, %{"thread_id" => thread.id, "model" => "qwen"})
      refute_received {:title_request, _request}
      assert Threads.get_thread!(thread.id).title == "Mine"
    end

    test "only runs after completed runs", %{user: user, persona: persona} do
      enable(persona, %{"title" => %{}})
      thread = thread_fixture(user)
      {_message, run} = message_fixture(thread)
      stub_upstream_down()
      :ok = perform_job(Worker, %{"run_id" => run.id})

      refute_enqueued(worker: TitleWorker)
    end

    test "cleans up what models reply" do
      clean = &Meridian.Ext.Title.Worker.clean/1
      assert clean.("<think>Hmm.</think>\n\n**Trip to Rome.**") == "Trip to Rome"
      assert clean.("Title: \"Fixing CI\"\nMore text") == "Fixing CI"
      assert clean.("  ") == ""
    end
  end
end
