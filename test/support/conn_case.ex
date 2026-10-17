defmodule MeridianWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use MeridianWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint MeridianWeb.Endpoint

      use MeridianWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import MeridianWeb.ConnCase
    end
  end

  setup tags do
    Meridian.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Sets Meridian's client at the OIDC provider (`OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`) for one
  test, which turns sign-in on. Tests that use it can't be async.
  """
  def put_oidc_client(client_id, client_secret \\ nil) do
    previous = Application.fetch_env!(:meridian, Meridian.OIDC)

    Application.put_env(
      :meridian,
      Meridian.OIDC,
      Keyword.merge(previous, client_id: client_id, client_secret: client_secret)
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:meridian, Meridian.OIDC, previous) end)
  end

  @doc """
  Logs `conn` into the admin console with the configured `ADMIN_TOKEN`.

      setup :log_in_admin
  """
  def log_in_admin(%{conn: conn}) do
    token = Application.fetch_env!(:meridian, :admin_token)

    conn =
      Phoenix.ConnTest.dispatch(conn, MeridianWeb.Endpoint, :post, "/admin/login", %{
        "token" => token
      })

    # Recycling carries the session cookie over to the next request.
    %{conn: Phoenix.ConnTest.recycle(conn)}
  end

  @doc """
  Signs `user` in to `/me` through the stubbed OIDC provider (`Meridian.OIDCStub`), linking
  them on a first sign-in, and returns the recycled conn. Needs `put_oidc_client/2` first.
  """
  def log_in_me(conn, user, subject \\ "user_#{System.unique_integer([:positive])}") do
    alias Meridian.OIDCStub

    OIDCStub.stub()
    conn = Phoenix.ConnTest.dispatch(conn, MeridianWeb.Endpoint, :get, "/me/auth/oidc")
    "https://auth.test/oauth2/authorize?" <> query = Phoenix.ConnTest.redirected_to(conn, 302)
    query = URI.decode_query(query)
    client_id = Meridian.OIDC.client()[:client_id]

    OIDCStub.stub(
      token: fn _params ->
        claims = %{
          "sub" => subject,
          "email" => user.email,
          "aud" => client_id,
          "nonce" => query["nonce"]
        }

        %{
          "id_token" => OIDCStub.sign(claims),
          "access_token" => "opaque",
          "token_type" => "Bearer"
        }
      end
    )

    conn =
      conn
      |> Phoenix.ConnTest.recycle()
      |> Phoenix.ConnTest.dispatch(MeridianWeb.Endpoint, :get, "/me/auth/callback", %{
        "code" => "c",
        "state" => query["state"]
      })

    "/me" = Phoenix.ConnTest.redirected_to(conn)
    Phoenix.ConnTest.recycle(conn)
  end
end
