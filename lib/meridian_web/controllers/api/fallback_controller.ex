defmodule MeridianWeb.Api.FallbackController do
  @moduledoc """
  Turns the `{:error, ...}` results of the native API's controllers into error responses, in
  the same `{"error": {...}}` shape as `/v1`.
  """
  use MeridianWeb, :controller

  alias MeridianWeb.V1.OpenAIError

  def call(conn, nil), do: call(conn, {:error, :not_found})

  def call(conn, {:error, :not_found}),
    do: OpenAIError.send_error(conn, 404, "not_found", "Not found.")

  def call(conn, {:error, :persona_not_found}) do
    OpenAIError.send_error(
      conn,
      422,
      "persona_not_found",
      "The persona does not exist or this API key may not use it."
    )
  end

  def call(conn, {:error, :run_active}) do
    OpenAIError.send_error(
      conn,
      409,
      "run_active",
      "The thread already has an active run. Wait for it to finish or cancel it."
    )
  end

  def call(conn, {:error, :invalid_cursor}) do
    OpenAIError.send_error(conn, 400, "invalid_cursor", "`after` must be a non-negative integer.")
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, &MeridianWeb.CoreComponents.translate_error/1)

    message =
      Enum.map_join(errors, "; ", fn {field, messages} ->
        "#{field} #{Enum.join(messages, ", ")}"
      end)

    OpenAIError.send_error(conn, 422, "invalid_request", message)
  end
end
