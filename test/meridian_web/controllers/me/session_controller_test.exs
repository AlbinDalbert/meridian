defmodule MeridianWeb.Me.SessionControllerTest do
  # Not async: tests change the OIDC client application env.
  use MeridianWeb.ConnCase

  import Meridian.Fixtures

  alias Meridian.Accounts
  alias Meridian.Accounts.User
  alias Meridian.OIDCStub
  alias Meridian.Repo

  @moduletag :capture_log

  setup do
    put_oidc_client("me_client", "me_secret")
    %{user: user_fixture(%{"name" => "Ada", "email" => "Ada@Example.com"})}
  end

  defp start_sign_in(conn) do
    OIDCStub.stub()
    conn = get(conn, ~p"/me/auth/oidc")
    assert "https://auth.test/oauth2/authorize?" <> query = redirected_to(conn, 302)
    {recycle(conn), URI.decode_query(query)}
  end

  defp stub_provider(query, claims) do
    OIDCStub.stub(
      token: fn _params ->
        id_token =
          OIDCStub.sign(Map.merge(%{"aud" => "me_client", "nonce" => query["nonce"]}, claims))

        %{"id_token" => id_token, "access_token" => "opaque", "token_type" => "Bearer"}
      end
    )
  end

  defp callback(conn, query, params \\ %{}) do
    get(
      conn,
      ~p"/me/auth/callback",
      Map.merge(%{"code" => "c", "state" => query["state"]}, params)
    )
  end

  test "without a session, /me goes to the sign-in page", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/me")) == ~p"/me/login"
    assert conn |> get(~p"/me/login") |> html_response(200) =~ ~s(href="/me/auth/oidc")
  end

  test "signing in links the user and shows their agents", %{conn: conn, user: user} do
    {conn, query} = start_sign_in(conn)
    assert query["client_id"] == "me_client"
    assert query["redirect_uri"] == url(~p"/me/auth/callback")
    assert query["code_challenge_method"] == "S256"

    stub_provider(query, %{"sub" => "user_ada", "email" => "ada@example.com"})
    conn = callback(conn, query)
    assert redirected_to(conn) == ~p"/me"

    assert_received {:oidc_request, "/oauth2/token", params}
    assert params["client_secret"] == "me_secret"
    assert params["redirect_uri"] == url(~p"/me/auth/callback")

    assert %User{oidc_issuer: "https://auth.test", oidc_subject: "user_ada"} =
             Repo.get!(User, user.id)

    conn = recycle(conn)
    html = conn |> get(~p"/me") |> html_response(200)
    assert html =~ "Your agents"
    assert html =~ "meridian/default"
    assert get(conn, ~p"/me/login") |> redirected_to() == ~p"/me"

    # A /me session is not an admin session.
    assert redirected_to(get(conn, ~p"/admin/users")) == ~p"/admin/login"

    # Logging out ends it.
    conn = conn |> post(~p"/me/logout") |> recycle()
    assert redirected_to(get(conn, ~p"/me")) == ~p"/me/login"
  end

  test "someone without a user is refused", %{conn: conn} do
    {conn, query} = start_sign_in(conn)
    stub_provider(query, %{"sub" => "user_bob", "email" => "bob@example.com"})

    conn = callback(conn, query)
    assert html_response(conn, 403) =~ "bob@example.com doesn&#39;t have a Meridian user"
    assert redirected_to(get(recycle(conn), ~p"/me")) == ~p"/me/login"
  end

  test "an unverified email isn't linked", %{conn: conn} do
    {conn, query} = start_sign_in(conn)

    stub_provider(query, %{
      "sub" => "user_ada",
      "email" => "ada@example.com",
      "email_verified" => false
    })

    assert html_response(callback(conn, query), 403) =~ "have a Meridian user"
  end

  test "a wrong state, a missing flow cookie, or a wrong nonce fails", %{conn: conn} do
    {flow_conn, query} = start_sign_in(conn)
    stub_provider(query, %{"sub" => "user_ada", "email" => "ada@example.com"})

    assert html_response(callback(flow_conn, query, %{"state" => "forged"}), 401) =~
             "Sign-in failed"

    assert html_response(callback(build_conn(), query), 401) =~ "Sign-in failed"

    stub_provider(%{"nonce" => "other"}, %{"sub" => "user_ada", "email" => "ada@example.com"})
    assert html_response(callback(flow_conn, query), 401) =~ "Sign-in failed"
  end

  test "cancelling at the provider says so", %{conn: conn} do
    {conn, query} = start_sign_in(conn)

    conn =
      get(conn, ~p"/me/auth/callback", %{"error" => "access_denied", "state" => query["state"]})

    assert html_response(conn, 401) =~ "Sign-in was cancelled"
  end

  test "deleting the user or unlinking the sign-in ends the session", %{conn: conn, user: user} do
    conn = log_in_me(conn, user)
    assert conn |> get(~p"/me") |> html_response(200)

    {:ok, _} = Accounts.unlink_oidc_identity(Repo.get!(User, user.id))
    assert redirected_to(get(conn, ~p"/me")) == ~p"/me/login"
  end

  test "without user sign-in set up, /me is 404", %{conn: conn} do
    put_oidc_client(nil)
    assert response(get(conn, ~p"/me"), 404)
    assert response(get(conn, ~p"/me/login"), 404)
    assert response(get(conn, ~p"/me/auth/oidc"), 404)
  end
end
