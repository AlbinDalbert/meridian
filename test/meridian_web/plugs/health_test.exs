defmodule MeridianWeb.Plugs.HealthTest do
  use MeridianWeb.ConnCase, async: true

  test "GET /healthz", %{conn: conn} do
    assert conn |> get("/healthz") |> text_response(200) == "ok"
  end

  test "GET /readyz reports the database as reachable", %{conn: conn} do
    assert conn |> get("/readyz") |> text_response(200) == "ok"
  end
end
