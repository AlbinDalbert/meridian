defmodule MeridianWeb.Admin.OIDCControllerTest do
  # Not async: tests change the OIDC client, :admin_emails, and :admin_token application env.
  use MeridianWeb.ConnCase

  alias Meridian.OIDC
  alias Meridian.OIDCStub

  @moduletag :capture_log

  setup do
    put_oidc_client("admin_client", "admin_secret")
    put_env(:admin_emails, ["ops@example.com"])

    :ok
  end

  # Starts sign-in and returns the conn (carrying the flow cookie) and the authorize URL's query.
  defp start_sign_in(conn) do
    conn = get(conn, ~p"/admin/auth/oidc")
    location = redirected_to(conn, 302)
    assert "https://auth.test/oauth2/authorize?" <> query = location
    {recycle(conn), URI.decode_query(query)}
  end

  defp stub_provider(query, claims) do
    OIDCStub.stub(
      token: fn _params ->
        id_token =
          OIDCStub.sign(Map.merge(%{"aud" => "admin_client", "nonce" => query["nonce"]}, claims))

        %{"id_token" => id_token, "access_token" => "opaque", "token_type" => "Bearer"}
      end,
      userinfo: %{"sub" => claims["sub"], "email" => "ops@example.com", "email_verified" => true}
    )
  end

  test "the login page offers sign-in, with the token as a fallback", %{conn: conn} do
    html = conn |> get(~p"/admin/login") |> html_response(200)
    assert html =~ ~s(href="/admin/auth/oidc")
    assert html =~ "Use the admin token instead"
  end

  test "signing in with an allowed email starts an admin session", %{conn: conn} do
    OIDCStub.stub()
    {conn, query} = start_sign_in(conn)

    assert query["client_id"] == "admin_client"
    assert query["redirect_uri"] == url(~p"/admin/auth/callback")
    assert query["code_challenge_method"] == "S256"
    assert query["scope"] =~ "openid"

    stub_provider(query, %{"sub" => "user_ops", "email" => "OPS@example.com"})

    conn = get(conn, ~p"/admin/auth/callback", %{"code" => "the-code", "state" => query["state"]})
    assert html_response(conn, 200) =~ ~s(http-equiv="refresh")

    assert_received {:oidc_request, "/oauth2/token", params}
    assert params["code"] == "the-code"
    assert params["client_secret"] == "admin_secret"
    assert OIDC.code_challenge(params["code_verifier"]) == query["code_challenge"]

    conn = recycle(conn)
    assert html_response(get(conn, ~p"/admin/users"), 200) =~ "Users"

    # Taking the email off ADMIN_EMAILS ends the session.
    put_env(:admin_emails, ["someone@example.com"])
    assert redirected_to(get(recycle(conn), ~p"/admin/users")) == ~p"/admin/login"
  end

  test "falls back to userinfo when the ID token has no email", %{conn: conn} do
    OIDCStub.stub()
    {conn, query} = start_sign_in(conn)
    stub_provider(query, %{"sub" => "user_ops"})

    conn = get(conn, ~p"/admin/auth/callback", %{"code" => "c", "state" => query["state"]})
    assert html_response(conn, 200) =~ ~s(http-equiv="refresh")
  end

  test "an email not in ADMIN_EMAILS is refused", %{conn: conn} do
    OIDCStub.stub()
    {conn, query} = start_sign_in(conn)
    stub_provider(query, %{"sub" => "user_eve", "email" => "eve@example.com"})

    conn = get(conn, ~p"/admin/auth/callback", %{"code" => "c", "state" => query["state"]})
    assert html_response(conn, 403) =~ "eve@example.com isn&#39;t allowed"
    assert redirected_to(get(recycle(conn), ~p"/admin/users")) == ~p"/admin/login"
  end

  test "an unverified email is refused", %{conn: conn} do
    OIDCStub.stub()
    {conn, query} = start_sign_in(conn)

    stub_provider(query, %{
      "sub" => "user_ops",
      "email" => "ops@example.com",
      "email_verified" => false
    })

    conn = get(conn, ~p"/admin/auth/callback", %{"code" => "c", "state" => query["state"]})
    assert html_response(conn, 403) =~ "isn&#39;t verified"
  end

  test "a wrong state, a missing flow cookie, or a wrong nonce fails", %{conn: conn} do
    OIDCStub.stub()
    {flow_conn, query} = start_sign_in(conn)
    stub_provider(query, %{"sub" => "user_ops", "email" => "ops@example.com"})

    conn = get(flow_conn, ~p"/admin/auth/callback", %{"code" => "c", "state" => "forged"})
    assert html_response(conn, 401) =~ "Sign-in failed"

    conn =
      get(build_conn(), ~p"/admin/auth/callback", %{"code" => "c", "state" => query["state"]})

    assert html_response(conn, 401) =~ "Sign-in failed"

    stub_provider(%{"nonce" => "other"}, %{"sub" => "user_ops", "email" => "ops@example.com"})
    conn = get(flow_conn, ~p"/admin/auth/callback", %{"code" => "c", "state" => query["state"]})
    assert html_response(conn, 401) =~ "Sign-in failed"
  end

  test "an error from the provider is shown", %{conn: conn} do
    OIDCStub.stub()
    {conn, query} = start_sign_in(conn)

    conn =
      get(conn, ~p"/admin/auth/callback", %{"error" => "access_denied", "state" => query["state"]})

    assert html_response(conn, 401) =~ "access_denied"
  end

  test "with only OIDC sign-in, /admin is enabled and the token form is gone", %{conn: conn} do
    put_env(:admin_token, nil)
    html = conn |> get(~p"/admin/login") |> html_response(200)
    assert html =~ ~s(href="/admin/auth/oidc")
    refute html =~ "Admin token"
  end

  test "without ADMIN_EMAILS, admin sign-in is off and its routes are 404", %{conn: conn} do
    put_env(:admin_emails, [])
    assert response(get(conn, ~p"/admin/auth/oidc"), 404)
    refute conn |> get(~p"/admin/login") |> html_response(200) =~ "/admin/auth/oidc"
  end

  defp put_env(key, value) do
    previous = Application.fetch_env!(:meridian, key)
    Application.put_env(:meridian, key, value)
    on_exit(fn -> Application.put_env(:meridian, key, previous) end)
  end
end
