defmodule MeridianWeb.Admin.RedirectController do
  use MeridianWeb, :controller

  def users(conn, _params), do: redirect(conn, to: ~p"/admin/users")
end
