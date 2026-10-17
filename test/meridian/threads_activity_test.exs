defmodule Meridian.ThreadsActivityTest do
  use Meridian.DataCase, async: true
  use Oban.Testing, repo: Meridian.Repo

  import Meridian.Fixtures

  alias Meridian.Runs.Worker
  alias Meridian.Threads

  test "counts threads, messages, runs, and tokens, per user" do
    user = user_fixture()
    other = user_fixture()

    assert %{thread_count: 0, message_count: 0, run_count: 0, tokens_in: 0, tokens_out: 0} =
             Threads.activity(user)

    thread = thread_fixture(user)
    {_message, run} = message_fixture(thread, "Hi")
    stub_upstream_stream(completion_events(["Hello."]))
    :ok = perform_job(Worker, %{"run_id" => run.id})
    {_message, _queued} = message_fixture(thread_fixture(user), "Again")
    message_fixture(thread_fixture(other), "Not mine")

    assert %{
             thread_count: 2,
             message_count: 3,
             run_count: 2,
             tokens_in: 5,
             tokens_out: 2,
             last_active_at: %DateTime{}
           } = Threads.activity(user)
  end
end
