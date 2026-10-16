defmodule MeridianWeb.Plugs.Health do
  @moduledoc """
  Liveness and readiness probes, answered before routing and request logging.

    * `GET /healthz` - the VM is up and serving HTTP.
    * `GET /readyz`  - the database is reachable.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: ["healthz"]} = conn, _opts) do
    conn |> respond(200, "ok") |> halt()
  end

  def call(%Plug.Conn{method: "GET", path_info: ["readyz"]} = conn, _opts) do
    case database_ready?() do
      true -> conn |> respond(200, "ok") |> halt()
      false -> conn |> respond(503, "database unavailable") |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp database_ready? do
    match?({:ok, _}, Ecto.Adapters.SQL.query(Meridian.Repo, "SELECT 1", [], timeout: 1_000))
  rescue
    _ -> false
  end

  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end
end
