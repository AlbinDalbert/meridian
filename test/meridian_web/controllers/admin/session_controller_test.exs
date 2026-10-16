defmodule MeridianWeb.Admin.SessionControllerTest do
  # Not async: some tests change the :admin_token application env.
  use MeridianWeb.ConnCase

  test "the login page renders", %{conn: conn} do
    conn = get(conn, ~p"/admin/login")
    assert html_response(conn, 200) =~ "Admin token"
  end

  test "admin pages redirect to login without a session", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/admin/users")) == ~p"/admin/login"
    assert redirected_to(get(conn, ~p"/admin")) == ~p"/admin/login"
  end

  test "a wrong token is rejected", %{conn: conn} do
    conn = post(conn, ~p"/admin/login", %{"token" => "wrong"})
    assert html_response(conn, 401) =~ "isn&#39;t valid"
    assert redirected_to(conn |> recycle() |> get(~p"/admin/users")) == ~p"/admin/login"
  end

  test "the right token logs in, and logging out ends the session", %{conn: conn} do
    token = Application.fetch_env!(:meridian, :admin_token)
    conn = post(conn, ~p"/admin/login", %{"token" => token})
    assert redirected_to(conn) == ~p"/admin/users"

    [cookie] = get_resp_header(conn, "set-cookie")
    assert cookie =~ "path=/admin"
    assert cookie =~ "HttpOnly"
    assert cookie =~ "SameSite=Strict"

    conn = conn |> recycle() |> get(~p"/admin/users")
    assert html_response(conn, 200) =~ "Users"

    conn = conn |> recycle() |> post(~p"/admin/logout")
    assert redirected_to(conn) == ~p"/admin/login"
    assert redirected_to(conn |> recycle() |> get(~p"/admin/users")) == ~p"/admin/login"
  end

  describe "with a changed token" do
    setup :log_in_admin

    test "existing sessions stop working", %{conn: conn} do
      put_admin_token("a-completely-different-token-0123456789")
      assert redirected_to(get(conn, ~p"/admin/users")) == ~p"/admin/login"
    end
  end

  test "/admin is disabled without ADMIN_TOKEN", %{conn: conn} do
    put_admin_token(nil)
    assert response(get(conn, ~p"/admin/login"), 404)
    assert response(build_conn() |> get(~p"/admin/users"), 404)
  end

  defp put_admin_token(token) do
    previous = Application.fetch_env!(:meridian, :admin_token)
    Application.put_env(:meridian, :admin_token, token)
    on_exit(fn -> Application.put_env(:meridian, :admin_token, previous) end)
  end
end
