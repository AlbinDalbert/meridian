defmodule MeridianWeb.Me.MeLiveTest do
  # Not async: signing in changes the OIDC client application env.
  use MeridianWeb.ConnCase

  import Phoenix.LiveViewTest
  import Meridian.Fixtures

  alias Meridian.Personas

  @moduletag :capture_log

  setup %{conn: conn} do
    put_oidc_client("me_client")
    user = user_fixture()
    %{conn: log_in_me(conn, user), user: user}
  end

  test "LiveViews require a /me session" do
    assert {:error, {:redirect, %{to: "/me/login"}}} = live(build_conn(), ~p"/me")
  end

  test "lists only the signed-in user's personas", %{conn: conn, user: user} do
    persona_fixture(user, %{"slug" => "mine"})
    other = persona_fixture(user_fixture(), %{"slug" => "theirs"})

    {:ok, _lv, html} = live(conn, ~p"/me")
    assert html =~ "meridian/mine"
    refute html =~ "meridian/theirs"

    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/me/personas/#{other}/edit") end
  end

  test "creating and editing a persona", %{conn: conn, user: user} do
    stub_upstream_models(["qwen"])
    {:ok, lv, _html} = live(conn, ~p"/me/personas/new")

    attrs = %{slug: "coder", name: "Coder", model: "nope", params: ~s({"temperature": 0.2})}

    assert lv |> form("#persona-form", persona: attrs) |> render_submit() =~
             "is not offered by the upstream"

    {:ok, _lv, html} =
      lv
      |> form("#persona-form", persona: %{attrs | model: "qwen"})
      |> render_submit()
      |> follow_redirect(conn, ~p"/me")

    assert html =~ "Persona saved."
    assert html =~ "meridian/coder"
    persona = Personas.get_persona_by_slug(user, "coder")
    assert %{model: "qwen", params: %{"temperature" => 0.2}} = persona

    {:ok, lv, _html} = live(conn, ~p"/me/personas/#{persona}/edit")

    {:ok, _lv, _html} =
      lv
      |> form("#persona-form",
        persona: %{system_prompt: "Be terse."},
        extensions: %{datetime: %{enabled: "true"}}
      )
      |> render_submit()
      |> follow_redirect(conn, ~p"/me")

    assert %{system_prompt: "Be terse.", extensions: %{"datetime" => _}} =
             Personas.get_persona!(persona.id)
  end

  test "making a persona the default and deleting personas", %{conn: conn, user: user} do
    persona = persona_fixture(user, %{"slug" => "coder"})
    {:ok, lv, _html} = live(conn, ~p"/me")

    lv |> element("#personas button", "Make default") |> render_click()
    assert Personas.get_default_persona(user).id == persona.id

    lv |> element("#personas button", "Delete") |> render_click()
    assert Personas.get_persona_by_slug(user, "default") == nil
  end
end
