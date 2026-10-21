defmodule MeridianWeb.PageController do
  @moduledoc "The front page: pick where to sign in, the admin console or `/me`."
  use MeridianWeb, :controller

  alias MeridianWeb.{AdminAuth, MeAuth}

  def home(conn, _params) do
    render(conn, :home, admin: AdminAuth.enabled?(), me: MeAuth.enabled?())
  end
end
