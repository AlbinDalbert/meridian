defmodule MeridianWeb.Me.AccessRequestControllerTest do
  # Not async: tests change the OIDC client application env.
  use MeridianWeb.ConnCase

  import Meridian.Fixtures

  alias Meridian.AccessRequests

  setup do
    put_oidc_client("me_client")
    :ok
  end

  test "the page asks for an email and a name", %{conn: conn} do
    html = conn |> get(~p"/me/request") |> html_response(200)
    assert html =~ ~s(name="request[email]")
    assert html =~ ~s(name="request[name]")
    assert html =~ "/assets/public.css"
  end

  test "sending a request thanks you and records it", %{conn: conn} do
    html =
      conn
      |> post(~p"/me/request", %{"request" => %{"email" => "bob@example.com", "name" => "Bob"}})
      |> html_response(200)

    assert html =~ "Request sent"
    assert html =~ "bob@example.com"
    assert [%{email: "bob@example.com", name: "Bob"}] = AccessRequests.list_requests("pending")
  end

  test "an email that already has a user gets the same answer", %{conn: conn} do
    user_fixture(%{"email" => "ada@example.com"})

    html =
      conn
      |> post(~p"/me/request", %{"request" => %{"email" => "ada@example.com"}})
      |> html_response(200)

    assert html =~ "Request sent"
    assert AccessRequests.list_requests("pending") == []
  end

  test "an invalid email is shown", %{conn: conn} do
    html =
      conn
      |> post(~p"/me/request", %{"request" => %{"email" => "nope", "name" => "Bob"}})
      |> html_response(422)

    assert html =~ "must be a valid email address"
    assert html =~ ~s(value="Bob")
  end

  test "posting needs a CSRF token", %{conn: conn} do
    conn = Plug.Conn.put_private(conn, :plug_skip_csrf_protection, false)

    assert_error_sent 403, fn ->
      post(conn, ~p"/me/request", %{"request" => %{"email" => "bob@example.com"}})
    end
  end

  test "without user sign-in set up, the page is 404", %{conn: conn} do
    put_oidc_client(nil)
    assert response(get(conn, ~p"/me/request"), 404)
  end
end
