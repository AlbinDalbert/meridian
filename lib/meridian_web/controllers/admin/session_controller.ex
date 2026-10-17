defmodule MeridianWeb.Admin.SessionController do
  use MeridianWeb, :controller

  alias MeridianWeb.AdminAuth

  # The login pages are front-door pages like the request page, in the admin console's green.
  plug :put_root_layout, html: {MeridianWeb.Layouts, :public_root}
  plug :assign_theme

  def new(conn, _params) do
    if AdminAuth.admin_session?(get_session(conn)) do
      redirect(conn, to: ~p"/admin/users")
    else
      render(conn, :new, page_title: "Log in")
    end
  end

  def create(conn, %{"token" => token}) do
    if AdminAuth.valid_token?(token) do
      conn
      |> AdminAuth.log_in()
      |> redirect(to: ~p"/admin/users")
    else
      conn
      |> put_status(:unauthorized)
      |> put_flash(:error, "That token isn't valid.")
      |> render(:new, page_title: "Log in")
    end
  end

  def create(conn, _params), do: create(conn, %{"token" => ""})

  def delete(conn, _params) do
    conn
    |> AdminAuth.log_out()
    |> redirect(to: ~p"/admin/login")
  end

  defp assign_theme(conn, _opts), do: assign(conn, :theme, "admin")
end
