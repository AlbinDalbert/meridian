defmodule MeridianWeb.Admin.AdminLiveTest do
  use MeridianWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Meridian.Fixtures

  alias Meridian.{Accounts, Personas}

  setup :log_in_admin

  test "LiveViews require an admin session" do
    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(build_conn(), ~p"/admin/users")
  end

  test "creating a user creates their default persona", %{conn: conn} do
    stub_upstream_models(["qwen", "llama"])
    {:ok, lv, html} = live(conn, ~p"/admin/users/new")
    assert html =~ "Default persona"

    assert lv
           |> form("#user-form", user: %{name: "Ada"}, persona: %{model: "nope"})
           |> render_submit() =~ "is not offered by the upstream"

    {:ok, _lv, html} =
      lv
      |> form("#user-form", user: %{name: "Ada"}, persona: %{model: "qwen"})
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "User created."
    assert html =~ "meridian/default"
    assert [%{name: "Ada"} = user] = Accounts.list_users()
    assert %{model: "qwen"} = Personas.get_default_persona(user)
  end

  test "minting a key shows the token once", %{conn: conn} do
    user = user_fixture()
    {:ok, lv, _html} = live(conn, ~p"/admin/users/#{user}/keys/new")

    html =
      lv
      |> form("#api-key-form", api_key: %{name: "laptop", policy: %{default_persona: "default"}})
      |> render_submit()

    assert [api_key] = Accounts.list_api_keys(user)
    assert %{name: "laptop", policy: %{default_persona: "default"}} = api_key

    token =
      lv |> element("#minted-token") |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

    assert html =~ token
    assert {:ok, _} = Accounts.authenticate_api_key(token)
  end

  test "revoking a key", %{conn: conn} do
    user = user_fixture()
    api_key = api_key_fixture(user)
    {:ok, lv, _html} = live(conn, ~p"/admin/users/#{user}")

    assert lv |> element("#api-keys button", "Revoke") |> render_click() =~ "API key revoked."
    assert Accounts.authenticate_api_key(api_key.token) == :error
  end

  test "creating and editing a persona", %{conn: conn} do
    user = user_fixture()
    stub_upstream_down()
    {:ok, lv, _html} = live(conn, ~p"/admin/users/#{user}/personas/new")

    attrs = %{slug: "coder", name: "Coder", model: "qwen", params: ~s({"temperature": 0.2})}

    assert lv |> form("#persona-form", persona: attrs) |> render_submit() =~
             "upstream unreachable"

    assert lv
           |> form("#persona-form", persona: %{attrs | params: "nope"}, force: "true")
           |> render_submit() =~
             "is invalid"

    {:ok, _lv, html} =
      lv
      |> form("#persona-form", persona: attrs, force: "true")
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "meridian/coder"
    persona = Personas.get_persona_by_slug(user, "coder")
    assert persona.params == %{"temperature" => 0.2}

    {:ok, lv, html} = live(conn, ~p"/admin/personas/#{persona}/edit")
    assert html =~ "temperature"

    {:ok, _lv, _html} =
      lv
      |> form("#persona-form", persona: %{system_prompt: "Be terse."})
      |> render_submit()
      |> follow_redirect(conn)

    assert Personas.get_persona!(persona.id).system_prompt == "Be terse."
  end

  test "making a persona the default and deleting personas", %{conn: conn} do
    user = user_fixture()
    persona = persona_fixture(user, %{"slug" => "coder"})
    {:ok, lv, _html} = live(conn, ~p"/admin/users/#{user}")

    lv |> element("#personas button", "Make default") |> render_click()
    assert Personas.get_default_persona(user).id == persona.id

    lv |> element("#personas button", "Delete") |> render_click()
    assert Personas.get_persona_by_slug(user, "default") == nil
  end
end
