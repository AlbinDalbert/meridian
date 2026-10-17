defmodule MeridianWeb.Api.AuthControllerTest do
  # Not async: tests change the OIDC client application env.
  use MeridianWeb.ConnCase

  import Meridian.Fixtures

  alias Meridian.Accounts
  alias Meridian.Accounts.User
  alias Meridian.OIDC
  alias Meridian.OIDCStub
  alias Meridian.Repo

  @moduletag :capture_log

  setup do
    put_oidc_client("web_client")
    %{user: user_fixture(%{"email" => "Ada@Example.com"})}
  end

  # Starts sign-in through a proxy like xebec's, and returns the conn (carrying the flow cookie)
  # and the authorize URL's query.
  defp start_sign_in(conn, params \\ %{}) do
    conn =
      conn
      |> put_req_header("x-forwarded-host", "chat.example.com")
      |> put_req_header("x-forwarded-proto", "https")
      |> get(~p"/api/auth/login", params)

    assert "https://auth.test/oauth2/authorize?" <> query = redirected_to(conn, 302)
    {recycle(conn), URI.decode_query(query)}
  end

  defp stub_provider(query, claims) do
    OIDCStub.stub(
      token: fn _params ->
        id_token =
          OIDCStub.sign(Map.merge(%{"aud" => "web_client", "nonce" => query["nonce"]}, claims))

        %{"id_token" => id_token, "access_token" => "opaque", "token_type" => "Bearer"}
      end
    )
  end

  defp callback(conn, query, params \\ %{}) do
    conn
    |> put_req_header("x-forwarded-host", "chat.example.com")
    |> put_req_header("x-forwarded-proto", "https")
    |> get(~p"/api/auth/callback", Map.merge(%{"code" => "c", "state" => query["state"]}, params))
  end

  defp signed_in(conn), do: conn |> recycle() |> put_req_header("x-requested-with", "test")

  test "session says sign-in is available, and nobody is signed in", %{conn: conn} do
    assert %{"data" => %{"sign_in" => true, "user" => nil, "account_url" => account_url}} =
             conn |> get(~p"/api/auth/session") |> json_response(200)

    assert account_url == MeridianWeb.Endpoint.url() <> "/me"

    put_oidc_client(nil)

    assert %{"data" => %{"sign_in" => false}} =
             build_conn() |> get(~p"/api/auth/session") |> json_response(200)

    assert build_conn() |> get(~p"/api/auth/login") |> response(404)
  end

  test "signing in links the user and starts a session the API accepts", %{
    conn: conn,
    user: user
  } do
    OIDCStub.stub()
    {conn, query} = start_sign_in(conn, %{"return_to" => "/#thread-1"})

    assert query["client_id"] == "web_client"
    assert query["redirect_uri"] == "https://chat.example.com/api/auth/callback"
    assert query["code_challenge_method"] == "S256"

    stub_provider(query, %{"sub" => "user_ada", "email" => "ada@example.com"})
    conn = callback(conn, query)
    assert redirected_to(conn) == "/#thread-1"
    assert get_resp_cookies(conn)["_meridian_user"].secure

    assert_received {:oidc_request, "/oauth2/token", params}
    assert params["client_id"] == "web_client"
    assert params["redirect_uri"] == "https://chat.example.com/api/auth/callback"
    refute Map.has_key?(params, "client_secret")
    assert OIDC.code_challenge(params["code_verifier"]) == query["code_challenge"]

    assert %User{oidc_issuer: "https://auth.test", oidc_subject: "user_ada"} =
             Repo.get!(User, user.id)

    conn = signed_in(conn)

    assert %{"data" => %{"user" => %{"id" => id}}} =
             conn |> get(~p"/api/auth/session") |> json_response(200)

    assert id == user.id

    thread = conn |> post(~p"/api/threads", %{}) |> json_response(201) |> Map.fetch!("data")
    assert %{"data" => [_]} = conn |> get(~p"/api/threads") |> json_response(200)

    # Runs carry an events token for the user, like for access tokens.
    %{"run" => run} =
      conn
      |> post(~p"/api/threads/#{thread["id"]}/messages", %{"content" => "Hi"})
      |> json_response(202)
      |> Map.fetch!("data")

    assert is_binary(run["events_token"])

    # The cookie is for /api only; /v1 stays bearer-only.
    assert %{"error" => %{"code" => "missing_api_key"}} =
             conn |> get(~p"/v1/models") |> json_response(401)

    # Logging out ends it.
    conn = conn |> post(~p"/api/auth/logout") |> recycle()

    assert %{"error" => %{"code" => "missing_api_key"}} =
             conn |> get(~p"/api/threads") |> json_response(401)
  end

  test "prompt=login asks the provider to sign in again", %{conn: conn} do
    OIDCStub.stub()
    {_conn, query} = start_sign_in(conn)
    refute Map.has_key?(query, "prompt")

    {_conn, query} = start_sign_in(build_conn(), %{"prompt" => "login"})
    assert query["prompt"] == "login"
    assert query["max_age"] == "0"
  end

  test "changes need X-Requested-With; reads don't", %{conn: conn} do
    OIDCStub.stub()
    {conn, query} = start_sign_in(conn)
    stub_provider(query, %{"sub" => "user_ada", "email" => "ada@example.com"})
    conn = conn |> callback(query) |> recycle()

    assert conn |> get(~p"/api/threads") |> json_response(200)

    assert %{"error" => %{"code" => "missing_requested_with"}} =
             conn |> recycle() |> post(~p"/api/threads", %{}) |> json_response(403)
  end

  test "deleting the user or unlinking the sign-in ends the session", %{conn: conn, user: user} do
    OIDCStub.stub()
    {conn, query} = start_sign_in(conn)
    stub_provider(query, %{"sub" => "user_ada", "email" => "ada@example.com"})
    conn = conn |> callback(query) |> signed_in()

    assert conn |> get(~p"/api/threads") |> json_response(200)
    {:ok, _} = Accounts.unlink_oidc_identity(Repo.get!(User, user.id))
    assert conn |> get(~p"/api/threads") |> json_response(401)
  end

  test "a sign-in without a matching user goes back with an error", %{conn: conn} do
    OIDCStub.stub()
    {conn, query} = start_sign_in(conn, %{"return_to" => "/?x=1#t"})
    stub_provider(query, %{"sub" => "user_bob", "email" => "bob@example.com"})

    conn = callback(conn, query)
    assert redirected_to(conn) == "/?sign_in_error=unknown_user&x=1#t"
    refute get_resp_cookies(conn)["_meridian_user"][:value]
  end

  test "an unverified email isn't linked", %{conn: conn} do
    OIDCStub.stub()
    {conn, query} = start_sign_in(conn)

    stub_provider(query, %{
      "sub" => "user_ada",
      "email" => "ada@example.com",
      "email_verified" => false
    })

    assert redirected_to(callback(conn, query)) == "/?sign_in_error=unknown_user"
  end

  test "a wrong state, a missing flow cookie, or a wrong nonce fails", %{conn: conn} do
    OIDCStub.stub()
    {flow_conn, query} = start_sign_in(conn)
    stub_provider(query, %{"sub" => "user_ada", "email" => "ada@example.com"})

    assert redirected_to(callback(flow_conn, query, %{"state" => "forged"})) ==
             "/?sign_in_error=failed"

    assert redirected_to(callback(build_conn(), query)) == "/?sign_in_error=failed"

    stub_provider(%{"nonce" => "other"}, %{"sub" => "user_ada", "email" => "ada@example.com"})
    assert redirected_to(callback(flow_conn, query)) == "/?sign_in_error=failed"
  end

  test "cancelling at the provider says so", %{conn: conn} do
    OIDCStub.stub()
    {conn, query} = start_sign_in(conn)

    conn =
      get(conn, ~p"/api/auth/callback", %{"error" => "access_denied", "state" => query["state"]})

    assert redirected_to(conn) == "/?sign_in_error=cancelled"
  end

  test "return_to only goes to paths on the same origin", %{conn: conn} do
    OIDCStub.stub()

    for bad <- ["//evil.example", "/\\evil.example", "https://evil.example", "evil"] do
      {conn, query} = start_sign_in(conn, %{"return_to" => bad})
      stub_provider(query, %{"sub" => "user_ada", "email" => "ada@example.com"})
      assert redirected_to(callback(conn, query)) == "/"
    end
  end

  test "a provider outage while starting goes back with an error", %{conn: conn} do
    Req.Test.stub(OIDC, &Plug.Conn.send_resp(&1, 500, "down"))
    conn = get(conn, ~p"/api/auth/login")
    assert redirected_to(conn) == "/?sign_in_error=unavailable"
  end
end
