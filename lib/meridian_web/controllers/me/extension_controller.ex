defmodule MeridianWeb.Me.ExtensionController do
  use MeridianWeb, :controller

  alias Meridian.Extensions

  @doc "Downloads the script of an extension the user can use (global, or their own)."
  def export(conn, %{"id" => id}) do
    extension = Extensions.get_available_extension!(conn.assigns.current_user, id)
    send_download(conn, {:binary, extension.source}, filename: extension.name <> ".lua")
  end
end
