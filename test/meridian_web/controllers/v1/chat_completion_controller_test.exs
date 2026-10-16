defmodule MeridianWeb.V1.ChatCompletionControllerTest do
  use MeridianWeb.ConnCase, async: true

  import Meridian.Fixtures

  alias Meridian.Personas

  setup %{conn: conn} do
    user = user_fixture(%{}, %{"model" => "qwen"})

    {:ok, _} =
      user
      |> Personas.get_default_persona()
      |> Personas.update_persona(%{
        "system_prompt" => "Be brief.",
        "params" => %{"temperature" => 0.3}
      })

    api_key = api_key_fixture(user)
    conn = put_req_header(conn, "authorization", "Bearer #{api_key.token}")

    %{conn: conn, user: user}
  end

  test "proxies a non-streaming request with the persona applied", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(Meridian.Upstream, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:upstream_request, conn.request_path, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "object" => "chat.completion",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hi."}}]
      })
    end)

    conn =
      post(conn, ~p"/v1/chat/completions?ignored=1", %{
        "model" => "meridian/default",
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      })

    assert %{"choices" => [%{"message" => %{"content" => "Hi."}}]} = json_response(conn, 200)

    assert_received {:upstream_request, "/v1/chat/completions", body}

    assert body == %{
             "model" => "qwen",
             "temperature" => 0.3,
             "messages" => [
               %{"role" => "system", "content" => "Be brief."},
               %{"role" => "user", "content" => "Hello"}
             ]
           }
  end

  test "relays a streaming response chunk by chunk", %{conn: conn} do
    events = [
      ~s(data: {"choices":[{"delta":{"content":"Hel"}}]}\n\n),
      ~s(data: {"choices":[{"delta":{"content":"lo"}}]}\n\n),
      "data: [DONE]\n\n"
    ]

    Req.Test.stub(Meridian.Upstream, fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce(events, conn, fn event, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, event)
        conn
      end)
    end)

    conn =
      post(conn, ~p"/v1/chat/completions", %{
        "model" => "meridian/default",
        "stream" => true,
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      })

    assert conn.status == 200
    assert conn.state == :chunked
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.resp_body == Enum.join(events)
  end

  test "passes upstream errors through", %{conn: conn} do
    Req.Test.stub(Meridian.Upstream, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => %{"message" => "context length exceeded"}})
    end)

    conn =
      post(conn, ~p"/v1/chat/completions", %{"model" => "meridian/default", "messages" => []})

    assert %{"error" => %{"message" => "context length exceeded"}} = json_response(conn, 400)
  end

  @tag :capture_log
  test "returns 502 when the upstream is down", %{conn: conn} do
    stub_upstream_down()

    conn =
      post(conn, ~p"/v1/chat/completions", %{"model" => "meridian/default", "messages" => []})

    assert %{"error" => %{"code" => "upstream_unavailable"}} = json_response(conn, 502)
  end

  test "returns 404 for unknown personas", %{conn: conn} do
    conn = post(conn, ~p"/v1/chat/completions", %{"model" => "meridian/nope", "messages" => []})

    assert %{"error" => %{"code" => "model_not_found", "type" => "invalid_request_error"}} =
             json_response(conn, 404)
  end
end
