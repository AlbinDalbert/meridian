defmodule MeridianWeb.Admin.ExtensionController do
  use MeridianWeb, :controller

  alias Meridian.Extensions

  @doc "Downloads an extension's script."
  def export(conn, %{"id" => id}) do
    extension = Extensions.get_extension!(id)
    send_download(conn, {:binary, extension.source}, filename: extension.name <> ".lua")
  end
end
