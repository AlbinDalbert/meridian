defmodule Meridian.Fixtures do
  @moduledoc """
  Test helpers for creating users, personas, and API keys, plus a stubbed upstream.
  """
  alias Meridian.{Accounts, Personas}

  def unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  @doc "Creates a user with a default persona using `model` (validation skipped)."
  def user_fixture(attrs \\ %{}, persona_attrs \\ %{}) do
    {:ok, user} =
      Accounts.create_user(
        Map.merge(%{"name" => unique_name("user")}, attrs),
        Map.merge(%{"model" => "upstream-model"}, persona_attrs),
        force: true
      )

    user
  end

  def persona_fixture(user, attrs \\ %{}) do
    {:ok, persona} =
      Personas.create_persona(
        user,
        Map.merge(
          %{"slug" => unique_name("persona"), "name" => "Persona", "model" => "upstream-model"},
          attrs
        ),
        force: true
      )

    persona
  end

  @doc "Mints an API key. The plaintext token is in the `:token` field."
  def api_key_fixture(user, attrs \\ %{}) do
    {:ok, api_key} = Accounts.mint_api_key(user, Map.merge(%{"name" => "test key"}, attrs))
    api_key
  end

  @doc "Stubs the upstream's `GET /models` to list `ids`; other requests get a 500."
  def stub_upstream_models(ids) do
    Req.Test.stub(Meridian.Upstream, fn
      %Plug.Conn{method: "GET", request_path: "/v1/models"} = conn ->
        Req.Test.json(conn, %{
          "object" => "list",
          "data" => Enum.map(ids, &%{"id" => &1, "object" => "model"})
        })

      conn ->
        Plug.Conn.send_resp(conn, 500, "unexpected request")
    end)
  end

  @doc "Makes every upstream request fail as if the upstream were down."
  def stub_upstream_down do
    Req.Test.stub(Meridian.Upstream, &Req.Test.transport_error(&1, :econnrefused))
  end
end
