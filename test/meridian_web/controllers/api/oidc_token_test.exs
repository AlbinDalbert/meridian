defmodule MeridianWeb.OIDCTokenTest do
  use MeridianWeb.ConnCase, async: true
  use Oban.Testing, repo: Meridian.Repo

  import Meridian.Fixtures

  alias Meridian.Accounts.User
  alias Meridian.OIDCStub
  alias Meridian.Repo

  @moduletag :capture_log

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  setup do
    %{user: user_fixture(%{"email" => "Ada@Example.com"})}
  end

  test "links a first sign-in to the user with that email, then finds them by subject", %{
    conn: conn,
    user: user
  } do
    OIDCStub.stub(
      userinfo: %{"sub" => "user_ada", "email" => "ada@example.com", "email_verified" => true}
    )

    token = OIDCStub.sign(%{"sub" => "user_ada"})

    assert %{"data" => []} = conn |> authed(token) |> get(~p"/api/threads") |> json_response(200)
    assert_received {:oidc_request, "/oauth2/userinfo", ["Bearer " <> ^token]}

    assert %User{oidc_issuer: "https://auth.test", oidc_subject: "user_ada"} =
             Repo.get!(User, user.id)

    # Linked now: no userinfo call.
    assert build_conn() |> authed(token) |> get(~p"/v1/models") |> json_response(200)
    refute_received {:oidc_request, "/oauth2/userinfo", _}
  end

  test "threads and runs work, including the run's events token", %{conn: conn} do
    OIDCStub.stub(userinfo: %{"sub" => "user_ada", "email" => "ada@example.com"})
    conn = authed(conn, OIDCStub.sign(%{"sub" => "user_ada"}))

    thread = conn |> post(~p"/api/threads", %{}) |> json_response(201) |> Map.fetch!("data")

    %{"run" => run} =
      conn
      |> post(~p"/api/threads/#{thread["id"]}/messages", %{"content" => "Hi"})
      |> json_response(202)
      |> Map.fetch!("data")

    assert %{"data" => %{"events_token" => _}} =
             conn |> get(~p"/api/runs/#{run["id"]}") |> json_response(200)

    stub_upstream_stream(completion_events(["ok"]))
    :ok = perform_job(Meridian.Runs.Worker, %{"run_id" => run["id"]})

    path = ~p"/api/runs/#{run["id"]}/events"
    body = build_conn() |> get(path, %{"token" => run["events_token"]}) |> response(200)
    assert body =~ "run.completed"

    # Deleting the user revokes their events tokens.
    {:ok, _} = Meridian.Accounts.delete_user(Meridian.Accounts.get_user!(thread_owner(thread)))
    assert build_conn() |> get(path, %{"token" => run["events_token"]}) |> json_response(401)
  end

  defp thread_owner(%{"id" => id}), do: Repo.get!(Meridian.Threads.Thread, id).user_id

  test "an unknown email gets a helpful 401 and links nothing", %{conn: conn} do
    OIDCStub.stub(userinfo: %{"sub" => "user_bob", "email" => "bob@example.com"})
    conn = conn |> authed(OIDCStub.sign(%{"sub" => "user_bob"})) |> get(~p"/api/threads")
    assert %{"error" => %{"code" => "unknown_user"}} = json_response(conn, 401)
  end

  test "an unverified email is not linked", %{conn: conn} do
    OIDCStub.stub(
      userinfo: %{"sub" => "user_ada", "email" => "ada@example.com", "email_verified" => false}
    )

    conn = conn |> authed(OIDCStub.sign(%{"sub" => "user_ada"})) |> get(~p"/api/threads")
    assert %{"error" => %{"code" => "unknown_user"}} = json_response(conn, 401)
  end

  test "a user linked to another identity is not relinked", %{conn: conn, user: user} do
    user
    |> Ecto.Changeset.change(oidc_issuer: "https://auth.test", oidc_subject: "user_old")
    |> Repo.update!()

    OIDCStub.stub(userinfo: %{"sub" => "user_new", "email" => "ada@example.com"})

    conn = conn |> authed(OIDCStub.sign(%{"sub" => "user_new"})) |> get(~p"/api/threads")
    assert %{"error" => %{"code" => "unknown_user"}} = json_response(conn, 401)
  end

  test "rejects tokens for another audience, expired tokens, and forged ones", %{conn: conn} do
    OIDCStub.stub(userinfo: %{"sub" => "user_ada", "email" => "ada@example.com"})
    now = System.system_time(:second)

    for token <- [
          OIDCStub.sign(%{"sub" => "user_ada", "aud" => "admin_client"}),
          OIDCStub.sign(%{"sub" => "user_ada", "exp" => now - 3600}),
          OIDCStub.sign(%{"sub" => "user_ada"}, alg: "none")
        ] do
      conn = conn |> authed(token) |> get(~p"/api/threads")
      assert %{"error" => %{"code" => "invalid_api_key"}} = json_response(conn, 401)
    end
  end

  test "a provider outage is a 503, not a 401", %{conn: conn} do
    Req.Test.stub(Meridian.OIDC, &Plug.Conn.send_resp(&1, 500, "down"))
    conn = conn |> authed(OIDCStub.sign(%{"sub" => "user_ada"})) |> get(~p"/api/threads")
    assert %{"error" => %{"code" => "auth_unavailable"}} = json_response(conn, 503)
  end
end
