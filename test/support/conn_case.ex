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
end
