defmodule MeridianWeb.Admin.AccessRequestLiveTest do
  use MeridianWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Meridian.Fixtures

  alias Meridian.{AccessRequests, Accounts, Personas}

  setup :log_in_admin

  setup do
    stub_upstream_models(["qwen", "llama"])
    :ok
  end

  defp request!(email, name \\ nil) do
    {:ok, :requested} = AccessRequests.request_access(%{"email" => email, "name" => name})
    Enum.find(AccessRequests.list_requests("pending"), &(&1.email == email))
  end

  test "lists requests as cards, email first", %{conn: conn} do
    request!("bob@example.com", "Bob")
    {:ok, lv, html} = live(conn, ~p"/admin/requests")

    assert html =~ "bob@example.com"
    assert lv |> element("#pending-requests .request-name") |> render() =~ "Bob"

    # Asking again shows on the same card.
    {:ok, :requested} = AccessRequests.request_access(%{"email" => "bob@example.com"})
    {:ok, _lv, html} = live(conn, ~p"/admin/requests")
    assert html =~ "Asked 2 times"
    assert [_] = AccessRequests.list_requests("pending")
  end

  test "accepting adds the user with the model from the top of the page", %{conn: conn} do
    user_fixture(%{}, %{"model" => "qwen"})
    request = request!("bob@example.com", "Bob")
    {:ok, lv, _html} = live(conn, ~p"/admin/requests")

    # The newest user's model is suggested.
    assert lv |> element("#accept-model") |> render() =~ ~s(value="qwen")

    lv |> form("#accept-settings", %{"model" => "nope"}) |> render_change()
    html = lv |> element("#request-#{request.id} button", "Accept") |> render_click()
    assert html =~ "Couldn&#39;t add bob@example.com"
    assert html =~ "not offered by the upstream"

    lv |> form("#accept-settings", %{"model" => "llama"}) |> render_change()
    html = lv |> element("#request-#{request.id} button", "Accept") |> render_click()
    assert html =~ "Added bob@example.com"
    refute has_element?(lv, "#request-#{request.id}")

    user = Accounts.get_user_by_email("bob@example.com")
    assert %{name: "Bob"} = user
    assert %{model: "llama"} = Personas.get_default_persona(user)
  end

  test "snoozing, rejecting, and restoring", %{conn: conn} do
    request = request!("sam@example.com")
    {:ok, lv, _html} = live(conn, ~p"/admin/requests")

    lv |> element("#pending-requests button", "Snooze") |> render_click()
    assert has_element?(lv, "#snoozed-requests #request-#{request.id}")

    lv |> element("#snoozed-requests button", "Unsnooze") |> render_click()
    assert has_element?(lv, "#pending-requests #request-#{request.id}")

    lv |> element("#pending-requests button", "Reject") |> render_click()
    assert has_element?(lv, "#rejected-requests #request-#{request.id}")

    lv |> element("#rejected-requests button", "Restore") |> render_click()
    assert has_element?(lv, "#pending-requests #request-#{request.id}")
  end
end
