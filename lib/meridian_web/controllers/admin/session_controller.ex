defmodule MeridianWeb.Admin.SessionController do
  use MeridianWeb, :controller

  alias MeridianWeb.AdminAuth

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
end
