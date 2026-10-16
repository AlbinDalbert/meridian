defmodule MeridianWeb.Plugs.CORSTest do
  # Not async: one test changes the allowed origins.
  use MeridianWeb.ConnCase, async: false

  import Meridian.Fixtures

  @origin "https://app.example"

  defp preflight(conn, path, origin) do
    conn
    |> put_req_header("origin", origin)
    |> put_req_header("access-control-request-method", "POST")
    |> put_req_header(
      "access-control-request-headers",
      "authorization, content-type, x-stainless-os"
    )
    |> options(path)
  end

  test "answers preflight requests from allowed origins", %{conn: conn} do
    for path <- ["/api/threads", "/v1/chat/completions", "/api/runs/x/events"] do
      conn = preflight(conn, path, @origin)

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
      assert get_resp_header(conn, "vary") == ["origin"]
      assert [methods] = get_resp_header(conn, "access-control-allow-methods")
      assert methods =~ "PATCH"

      assert get_resp_header(conn, "access-control-allow-headers") ==
               ["authorization, content-type, x-stainless-os"]

      assert get_resp_header(conn, "access-control-allow-credentials") == []
    end
  end

  test "doesn't allow other origins", %{conn: conn} do
    conn = preflight(conn, "/api/threads", "https://evil.example")
    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == []
    assert get_resp_header(conn, "access-control-allow-methods") == []
  end

  test "adds the allow-origin header to responses, including errors", %{conn: conn} do
    conn = conn |> put_req_header("origin", @origin) |> get(~p"/api/threads")
    assert json_response(conn, 401)
    assert get_resp_header(conn, "access-control-allow-origin") == [@origin]

    api_key = api_key_fixture(user_fixture())

    conn =
      build_conn()
      |> put_req_header("origin", @origin)
      |> put_req_header("authorization", "Bearer #{api_key.token}")
      |> get(~p"/v1/models")

    assert json_response(conn, 200)
    assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
  end

  test "never applies to the admin console", %{conn: conn} do
    conn = conn |> put_req_header("origin", @origin) |> get(~p"/admin/login")
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end

  test "can allow any origin", %{conn: conn} do
    previous = Application.get_env(:meridian, :cors_allowed_origins)
    Application.put_env(:meridian, :cors_allowed_origins, :all)
    on_exit(fn -> Application.put_env(:meridian, :cors_allowed_origins, previous) end)

    conn = preflight(conn, "/api/threads", "https://anything.example")
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    assert get_resp_header(conn, "vary") == []
  end
end
