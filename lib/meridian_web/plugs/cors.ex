defmodule MeridianWeb.Plugs.CORS do
  @moduledoc """
  CORS for the client-facing APIs (`/v1`, `/api`), so browser apps on other origins can use
  them. Never applies to `/admin`.

  Allowed origins come from `CORS_ALLOWED_ORIGINS` (comma-separated, or `*`); unset means no
  cross-origin access. Credentials (cookies) are never allowed: the APIs authenticate with
  API keys only, so a page can't act for a user unless it has their key. That is also why
  allowing `*` is reasonable.

  Preflight (`OPTIONS`) requests are answered here and halted. Requested headers are allowed
  as asked, since clients such as the OpenAI SDK send their own `x-` headers.
  """
  @behaviour Plug

  import Plug.Conn

  @api_prefixes ["v1", "api"]
  @methods "GET, POST, PATCH, DELETE, OPTIONS"
  @max_age "600"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: [prefix | _]} = conn, _opts) when prefix in @api_prefixes do
    case get_req_header(conn, "origin") do
      [origin | _] -> handle(conn, origin, allowed_origins())
      [] -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp handle(conn, origin, allowed) do
    allowed? = allowed == :all or origin in allowed

    conn =
      if allowed? do
        conn
        |> put_resp_header(
          "access-control-allow-origin",
          if(allowed == :all, do: "*", else: origin)
        )
        |> vary_on_origin(allowed)
      else
        conn
      end

    if conn.method == "OPTIONS" and get_req_header(conn, "access-control-request-method") != [] do
      conn
      |> preflight_headers(allowed?)
      |> send_resp(204, "")
      |> halt()
    else
      conn
    end
  end

  defp preflight_headers(conn, false), do: conn

  defp preflight_headers(conn, true) do
    conn
    |> put_resp_header("access-control-allow-methods", @methods)
    |> put_resp_header("access-control-max-age", @max_age)
    |> then(fn conn ->
      case get_req_header(conn, "access-control-request-headers") do
        [headers | _] -> put_resp_header(conn, "access-control-allow-headers", headers)
        [] -> conn
      end
    end)
  end

  defp vary_on_origin(conn, :all), do: conn
  defp vary_on_origin(conn, _allowed), do: put_resp_header(conn, "vary", "origin")

  defp allowed_origins, do: Application.get_env(:meridian, :cors_allowed_origins, [])
end
