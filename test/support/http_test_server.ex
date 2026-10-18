defmodule Meridian.HTTPTestServer do
  @moduledoc """
  A real HTTP server on localhost for `Meridian.Extensions.HTTP`, which connects with Mint and
  so can't be stubbed with `Req.Test`. Start it with `start/0` from a test.
  """
  @behaviour Plug

  import Plug.Conn

  @doc "Starts the server under the test supervisor; returns its base URL."
  def start do
    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: __MODULE__, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["hello"]} = conn, _opts) do
    conn |> put_resp_header("x-test", "yes") |> send_resp(200, "hi")
  end

  def call(%Plug.Conn{path_info: ["echo"]} = conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    echo = %{method: conn.method, headers: Map.new(conn.req_headers), body: body}
    send_resp(conn, 200, Jason.encode!(echo))
  end

  def call(%Plug.Conn{path_info: ["status", status]} = conn, _opts) do
    send_resp(conn, String.to_integer(status), "status #{status}")
  end

  def call(%Plug.Conn{path_info: ["redirect", status], query_string: to} = conn, _opts) do
    conn
    |> put_resp_header("location", URI.decode(to))
    |> send_resp(String.to_integer(status), "")
  end

  def call(%Plug.Conn{path_info: ["loop"]} = conn, _opts) do
    conn |> put_resp_header("location", "/loop") |> send_resp(302, "")
  end

  def call(%Plug.Conn{path_info: ["big"]} = conn, _opts) do
    send_resp(conn, 200, String.duplicate("x", 1000))
  end

  def call(%Plug.Conn{path_info: ["slow"]} = conn, _opts) do
    Process.sleep(500)
    send_resp(conn, 200, "late")
  end
end
