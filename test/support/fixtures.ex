defmodule Meridian.Fixtures do
  @moduledoc """
  Test helpers for creating users, personas, and API keys, plus a stubbed upstream.
  """
  alias Meridian.{Accounts, Personas, Threads}
  alias Meridian.Accounts.ApiKey.Policy

  def unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  @doc "Creates a user with a default persona using `model` (validation skipped)."
  def user_fixture(attrs \\ %{}, persona_attrs \\ %{}) do
    {:ok, user} =
      Accounts.create_user(
        Map.merge(
          %{"name" => unique_name("user"), "email" => unique_name("user") <> "@example.com"},
          attrs
        ),
        Map.merge(%{"model" => "upstream-model"}, persona_attrs),
        force: true
      )

    user
  end

  def persona_fixture(user, attrs \\ %{}) do
    {:ok, persona} =
      Personas.create_persona(
        user,
        Map.merge(
          %{"slug" => unique_name("persona"), "name" => "Persona", "model" => "upstream-model"},
          attrs
        ),
        force: true
      )

    persona
  end

  @doc "Mints an API key. The plaintext token is in the `:token` field."
  def api_key_fixture(user, attrs \\ %{}) do
    {:ok, api_key} = Accounts.mint_api_key(user, Map.merge(%{"name" => "test key"}, attrs))
    api_key
  end

  def thread_fixture(user, attrs \\ %{}) do
    {:ok, thread} = Threads.create_thread(user, %Policy{}, attrs)
    thread
  end

  @doc "Sends a user message to `thread`, returning `{message, run}` (the run is queued)."
  def message_fixture(thread, content \\ "Hello") do
    {:ok, message, run} = Threads.send_message(thread, %Policy{}, %{"content" => content})
    {message, run}
  end

  @doc """
  Builds the SSE body of a streaming chat completion that sends `deltas` (strings, or delta
  maps such as `%{"reasoning_content" => "..."}`), then a finish reason, usage, and `[DONE]`.
  """
  def completion_events(deltas, opts \\ []) do
    chunks =
      for delta <- deltas do
        delta = if is_binary(delta), do: %{"content" => delta}, else: delta
        %{"choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => nil}]}
      end

    finish = %{
      "choices" => [
        %{"index" => 0, "delta" => %{}, "finish_reason" => Keyword.get(opts, :finish, "stop")}
      ]
    }

    usage = %{
      "choices" => [],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2, "total_tokens" => 7}
    }

    Enum.map(chunks ++ [finish, usage], &"data: #{Jason.encode!(&1)}\n\n") ++ ["data: [DONE]\n\n"]
  end

  @doc """
  Stubs a streaming chat completion that sends `events` (see `completion_events/2`) as separate
  chunks. Each request body is sent to the calling process as `{:upstream_request, body}`.
  """
  def stub_upstream_stream(events) do
    test_pid = self()

    Req.Test.stub(Meridian.Upstream, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:upstream_request, Jason.decode!(body)})

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce(events, conn, fn event, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, event)
        conn
      end)
    end)
  end

  @doc "Stubs the upstream's `GET /models` to list `ids`; other requests get a 500."
  def stub_upstream_models(ids) do
    Req.Test.stub(Meridian.Upstream, fn
      %Plug.Conn{method: "GET", request_path: "/v1/models"} = conn ->
        Req.Test.json(conn, %{
          "object" => "list",
          "data" => Enum.map(ids, &%{"id" => &1, "object" => "model"})
        })

      conn ->
        Plug.Conn.send_resp(conn, 500, "unexpected request")
    end)
  end

  @doc "Makes every upstream request fail as if the upstream were down."
  def stub_upstream_down do
    Req.Test.stub(Meridian.Upstream, &Req.Test.transport_error(&1, :econnrefused))
  end
end
