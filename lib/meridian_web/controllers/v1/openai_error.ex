defmodule MeridianWeb.V1.OpenAIError do
  @moduledoc """
  Errors in the shape OpenAI clients expect:
  `{"error": {"message": ..., "type": ..., "code": ...}}`.
  """
  import Plug.Conn

  @doc "Sends an OpenAI-style error response and halts."
  def send_error(conn, status, code, message) do
    body = %{error: %{message: message, type: type(status), param: nil, code: code}}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode_to_iodata!(body))
    |> halt()
  end

  defp type(401), do: "authentication_error"
  defp type(403), do: "permission_error"
  defp type(404), do: "invalid_request_error"
  defp type(status) when status in 400..499, do: "invalid_request_error"
  defp type(_status), do: "api_error"
end
