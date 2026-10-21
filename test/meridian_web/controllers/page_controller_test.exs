defmodule MeridianWeb.PageControllerTest do
  # Not async: tests change the OIDC client application env.
  use MeridianWeb.ConnCase

  test "the front page links to admin sign-in on the left and user sign-in on the right",
       %{conn: conn} do
    put_oidc_client("me_client", "me_secret")

    conn = get(conn, ~p"/")
    document = conn |> html_response(200) |> LazyHTML.from_document()

    links = document |> LazyHTML.query(".choices a.btn") |> LazyHTML.attribute("href")
    assert links == ["/admin", "/me"]

    # Public: no session.
    assert get_resp_header(conn, "set-cookie") == []
  end

  test "leaves out user sign-in when it isn't set up", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    links = document |> LazyHTML.query(".choices a.btn") |> LazyHTML.attribute("href")
    assert links == ["/admin"]
  end
end
