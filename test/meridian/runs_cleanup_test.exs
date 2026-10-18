defmodule Meridian.RunsCleanupTest do
  # The janitor failing queued runs whose job is gone, and pruning finished runs' deltas.
  use Meridian.DataCase, async: true
  use Oban.Testing, repo: Meridian.Repo

  import Meridian.Fixtures

  @moduletag :capture_log

  alias Meridian.Runs
  alias Meridian.Runs.{Event, EventPruner, Janitor, Run, Worker}

  setup do
    user = user_fixture(%{}, %{"model" => "qwen"})
    %{thread: thread_fixture(user)}
  end

  defp job_query(run) do
    from j in Oban.Job,
      where: j.worker == ^inspect(Worker) and fragment("?->>'run_id'", j.args) == ^run.id
  end

  defp event_types(run), do: run |> Runs.list_events() |> Enum.map(& &1.type)

  describe "queued runs" do
    test "with their job waiting are left alone", %{thread: thread} do
      {_message, run} = message_fixture(thread)

      assert Runs.fail_stale_runs(60_000) == 0
      assert %Run{status: :queued} = Runs.get_run!(run.id)
    end

    test "whose job is gone are failed, and the thread is free again", %{thread: thread} do
      {_message, run} = message_fixture(thread)
      {1, _} = Repo.delete_all(job_query(run))

      assert :ok = perform_job(Janitor, %{})
      assert %Run{status: :failed, error: %{"code" => "interrupted"}} = Runs.get_run!(run.id)
      assert event_types(run) == ~w(run.failed)

      assert {_message, _run} = message_fixture(thread, "Again")
    end

    test "whose job is discarded or completed are failed", %{thread: thread} do
      for state <- ~w(discarded completed cancelled) do
        {_message, run} = message_fixture(thread)
        {1, _} = Repo.update_all(job_query(run), set: [state: state])

        assert Runs.fail_stale_runs(60_000) == 1
        assert %Run{status: :failed} = Runs.get_run!(run.id)
      end
    end

    test "whose job started running recently are left alone, but not for long", %{
      thread: thread
    } do
      {_message, run} = message_fixture(thread)
      now = DateTime.utc_now()
      {1, _} = Repo.update_all(job_query(run), set: [state: "executing", attempted_at: now])

      assert Runs.fail_stale_runs(60_000) == 0

      # Its node died before the job could start the run.
      stale = DateTime.add(now, -120, :second)
      {1, _} = Repo.update_all(job_query(run), set: [attempted_at: stale])
      assert Runs.fail_stale_runs(60_000) == 1
      assert %Run{status: :failed} = Runs.get_run!(run.id)
    end

    test "running runs aren't failed because their job is gone", %{thread: thread} do
      {_message, run} = message_fixture(thread)
      {:ok, run, _started} = Runs.start_run(run.id)
      {1, _} = Repo.delete_all(job_query(run))

      # Their heartbeat decides.
      assert Runs.fail_stale_runs(60_000) == 0
      assert %Run{status: :running} = Runs.get_run!(run.id)
    end
  end

  describe "pruning deltas" do
    defp completed_run(thread, content) do
      {_message, run} = message_fixture(thread, content)
      stub_upstream_stream(completion_events(["Hel", "lo!"]))
      :ok = perform_job(Worker, %{"run_id" => run.id})
      run = Runs.get_run!(run.id)
      assert run.status == :completed
      assert "message.delta" in event_types(run)
      run
    end

    defp finished_ago(run, hours) do
      at = DateTime.add(DateTime.utc_now(), -hours, :hour)
      {1, _} = Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [finished_at: at])
    end

    test "deletes only the deltas of runs that finished long enough ago", %{thread: thread} do
      old = completed_run(thread, "Old")
      recent = completed_run(thread, "Recent")
      recent_types = event_types(recent)
      finished_ago(old, 25)
      finished_ago(recent, 23)

      deltas = Enum.count(event_types(old), &(&1 == "message.delta"))
      assert Runs.prune_deltas(:timer.hours(24)) == deltas

      assert event_types(old) == ~w(run.started message.completed run.completed)
      assert event_types(recent) == recent_types

      # The reply is still all there.
      completed = Enum.find(Runs.list_events(old), &(&1.type == "message.completed"))
      assert completed.payload["message"]["content"] == [%{"type" => "text", "text" => "Hello!"}]
    end

    test "leaves active runs alone", %{thread: thread} do
      {_message, run} = message_fixture(thread)
      {:ok, run, _started} = Runs.start_run(run.id)
      {:ok, _event} = Runs.append_event(run, 2, "message.delta", %{"content" => "Hi"})

      assert Runs.prune_deltas(0) == 0
      assert event_types(run) == ~w(run.started message.delta)
    end

    test "runs as a job", %{thread: thread} do
      run = completed_run(thread, "Old")
      finished_ago(run, 25)

      assert :ok = perform_job(EventPruner, %{})

      refute Repo.exists?(
               from e in Event, where: e.run_id == ^run.id and e.type == "message.delta"
             )
    end
  end
end
