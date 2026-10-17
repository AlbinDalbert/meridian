defmodule MeridianWeb.Admin.RunLiveTest do
  use MeridianWeb.ConnCase, async: true
  use Oban.Testing, repo: Meridian.Repo

  import Phoenix.LiveViewTest
  import Meridian.Fixtures

  alias Meridian.Runs.Worker

  setup :log_in_admin

  setup do
    user = user_fixture(%{"name" => "Ada"}, %{"slug" => "secret-persona"})
    thread = thread_fixture(user, %{"title" => "Trip plans"})
    {message, run} = message_fixture(thread, "Where to?")
    %{user: user, thread: thread, message: message, run: run}
  end

  # Nothing the user said, or what their thread or persona is called, ever reaches the console.
  defp refute_conversation(html) do
    for private <- ["Where to?", "To the mountains", "Trip plans", "secret-persona"],
        do: refute(html =~ private, "the admin console shows #{inspect(private)}")
  end

  test "the run view follows a run live, without its contents", %{conn: conn, run: run} do
    {:ok, lv, html} = live(conn, ~p"/admin/runs/#{run}")
    assert html =~ "queued"
    assert html =~ "Ada"
    refute_conversation(html)

    stub_upstream_stream(completion_events(["To the ", "mountains."]))
    :ok = perform_job(Worker, %{"run_id" => run.id})

    html = render(lv)
    assert html =~ "completed"
    assert has_element?(lv, "#events tr", "message.delta")
    assert has_element?(lv, "#events tr", "run.completed")
    assert html =~ "5 in / 2 out"
    refute_conversation(html)
  end

  test "the run view replays a finished run, without its contents", %{conn: conn, run: run} do
    stub_upstream_stream(completion_events(["To the mountains."]))
    :ok = perform_job(Worker, %{"run_id" => run.id})

    {:ok, lv, html} = live(conn, ~p"/admin/runs/#{run}")
    assert has_element?(lv, "#events tr", "message.completed")
    refute_conversation(html)
  end

  test "the runs page shows who ran what, not what was said", %{conn: conn, run: run} do
    stub_upstream_stream(completion_events(["To the mountains."]))
    :ok = perform_job(Worker, %{"run_id" => run.id})

    {:ok, _lv, html} = live(conn, ~p"/admin/runs")
    assert html =~ "Ada"
    assert html =~ "5 in / 2 out"
    refute_conversation(html)
  end

  test "the user page shows activity, not threads", %{conn: conn, user: user, run: run} do
    stub_upstream_stream(completion_events(["To the mountains."]))
    :ok = perform_job(Worker, %{"run_id" => run.id})

    {:ok, lv, html} = live(conn, ~p"/admin/users/#{user}")
    activity = lv |> element("#activity") |> render()
    assert activity =~ ~r/Threads<\/dt>\s*<dd>1</
    assert activity =~ ~r/Messages<\/dt>\s*<dd>2</
    assert activity =~ "5 in / 2 out"
    refute html =~ "Trip plans"
    refute html =~ "Where to?"
  end

  test "there is no thread view", %{conn: conn, thread: thread} do
    assert conn |> get("/admin/threads/#{thread.id}") |> response(404)
  end
end
