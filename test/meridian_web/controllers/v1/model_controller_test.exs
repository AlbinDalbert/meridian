defmodule MeridianWeb.V1.ModelControllerTest do
  use MeridianWeb.ConnCase, async: true

  import Meridian.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    persona_fixture(user, %{"slug" => "coder"})
    %{conn: conn, user: user}
  end

  test "requires an API key", %{conn: conn} do
    conn = get(conn, ~p"/v1/models")
    assert %{"error" => %{"code" => "missing_api_key"}} = json_response(conn, 401)

    conn =
      build_conn() |> put_req_header("authorization", "Bearer mrd_nope") |> get(~p"/v1/models")

    assert %{"error" => %{"code" => "invalid_api_key"}} = json_response(conn, 401)
  end

  test "lists the key's personas as models", %{conn: conn, user: user} do
    api_key = api_key_fixture(user)
    conn = conn |> authorize(api_key) |> get(~p"/v1/models")

    assert %{"object" => "list", "data" => data} = json_response(conn, 200)
    assert Enum.map(data, & &1["id"]) == ["meridian/default", "meridian/coder"]
    assert Enum.all?(data, &(&1["object"] == "model" and &1["owned_by"] == "meridian"))
  end

  test "respects the key's allowed personas", %{conn: conn, user: user} do
    api_key = api_key_fixture(user, %{"policy" => %{"allowed_personas" => ["coder"]}})
    conn = conn |> authorize(api_key) |> get(~p"/v1/models")

    assert %{"data" => [%{"id" => "meridian/coder"}]} = json_response(conn, 200)
  end

  defp authorize(conn, api_key),
    do: put_req_header(conn, "authorization", "Bearer #{api_key.token}")
end
