defmodule MeridianWeb.Admin.RunLiveTest do
  use MeridianWeb.ConnCase, async: true
  use Oban.Testing, repo: Meridian.Repo

  import Phoenix.LiveViewTest
  import Meridian.Fixtures

  alias Meridian.Runs.Worker

  setup :log_in_admin

  setup do
    user = user_fixture(%{"name" => "Ada"})
    thread = thread_fixture(user, %{"title" => "Trip plans"})
    {message, run} = message_fixture(thread, "Where to?")
    %{user: user, thread: thread, message: message, run: run}
  end

  test "the run view follows a run live", %{conn: conn, run: run} do
    {:ok, lv, html} = live(conn, ~p"/admin/runs/#{run}")
    assert html =~ "queued"
    assert html =~ "Where to?"

    stub_upstream_stream(completion_events(["To the ", "mountains."]))
    :ok = perform_job(Worker, %{"run_id" => run.id})

    html = render(lv)
    assert lv |> element("#run-text") |> render() =~ "To the mountains."
    assert html =~ "completed"
    assert html =~ "run.completed"
    assert html =~ "5 in / 2 out"
  end

  test "the run view replays a finished run", %{conn: conn, run: run} do
    stub_upstream_stream(completion_events(["Done."]))
    :ok = perform_job(Worker, %{"run_id" => run.id})

    {:ok, lv, _html} = live(conn, ~p"/admin/runs/#{run}")
    assert lv |> element("#run-text") |> render() =~ "Done."
    assert has_element?(lv, "#events tr", "message.completed")
  end

  test "the thread view shows messages and updates when a run ends", %{
    conn: conn,
    thread: thread,
    run: run
  } do
    {:ok, lv, html} = live(conn, ~p"/admin/threads/#{thread}")
    assert html =~ "Trip plans"
    assert html =~ "Where to?"

    stub_upstream_stream(completion_events(["The coast."]))
    :ok = perform_job(Worker, %{"run_id" => run.id})

    assert render(lv) =~ "The coast."
  end

  test "the runs page and user page link to runs and threads", %{conn: conn, user: user} do
    {:ok, _lv, html} = live(conn, ~p"/admin/runs")
    assert html =~ "Trip plans"
    assert html =~ "Ada"

    {:ok, _lv, html} = live(conn, ~p"/admin/users/#{user}")
    assert html =~ "Trip plans"
  end
end
