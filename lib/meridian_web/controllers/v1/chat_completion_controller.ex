defmodule MeridianWeb.V1.ChatCompletionController do
  @moduledoc """
  `POST /v1/chat/completions`: the persona proxy.

  The upstream response is relayed as it arrives, with the upstream's status and content type,
  so streaming (SSE) and non-streaming requests take the same path. If the client disconnects,
  the next write fails and the upstream request is cancelled.
  """
  use MeridianWeb, :controller

  require Logger

  alias Meridian.{Proxy, Upstream}
  alias MeridianWeb.V1.OpenAIError

  def create(conn, _params) do
    %{current_user: user, current_api_key: api_key} = conn.assigns
    # Only the JSON body is forwarded; `params` would also include the query string.
    params = conn.body_params

    case Proxy.resolve_model(user, api_key.policy, params["model"]) do
      {:ok, model} ->
        model |> Proxy.build_request(params) |> relay(conn)

      {:error, :model_not_found} ->
        OpenAIError.send_error(
          conn,
          404,
          "model_not_found",
          "The model `#{params["model"]}` does not exist or you do not have access to it."
        )
    end
  end

  defp relay(body, conn) do
    case Upstream.chat_completions(body) do
      {:ok, resp} ->
        conn
        |> put_resp_content_type(content_type(resp), nil)
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(resp.status)
        |> stream_body(resp)

      {:error, :not_configured} ->
        OpenAIError.send_error(conn, 503, "upstream_not_configured", "No upstream is configured.")

      {:error, reason} ->
        Logger.warning("Upstream chat completions request failed: #{inspect(reason)}")
        OpenAIError.send_error(conn, 502, "upstream_unavailable", "The upstream is unavailable.")
    end
  end

  defp stream_body(conn, resp) do
    Enum.reduce_while(resp.body, conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        # Halting the enumeration cancels the upstream request.
        {:error, _reason} -> {:halt, conn}
      end
    end)
  rescue
    # The upstream failed mid-response. The status line is already sent, so all we can do is
    # end the response.
    e ->
      Logger.warning("Upstream response failed mid-stream: #{Exception.message(e)}")
      conn
  end

  defp content_type(resp) do
    case Req.Response.get_header(resp, "content-type") do
      [content_type | _] -> content_type
      [] -> "application/json"
    end
  end
end
