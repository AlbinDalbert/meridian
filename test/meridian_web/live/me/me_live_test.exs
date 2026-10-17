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

    extension = extension_fixture(nil, "return {}")
    {:ok, lv, _html} = live(conn, ~p"/me/personas/#{persona}/edit")

    {:ok, _lv, _html} =
      lv
      |> form("#persona-form",
        persona: %{system_prompt: "Be terse."},
        extensions: %{extension.id => %{enabled: "true"}}
      )
      |> render_submit()
      |> follow_redirect(conn, ~p"/me")

    assert %{system_prompt: "Be terse.", extensions: extensions} =
             Personas.get_persona!(persona.id)

    assert Map.keys(extensions) == [extension.id]
  end

  test "making a persona the default and deleting personas", %{conn: conn, user: user} do
    persona = persona_fixture(user, %{"slug" => "coder"})
    {:ok, lv, _html} = live(conn, ~p"/me")

    lv |> element("#personas button", "Make default") |> render_click()
    assert Personas.get_default_persona(user).id == persona.id

    lv |> element("#personas button", "Delete") |> render_click()
    assert Personas.get_persona_by_slug(user, "default") == nil
  end

  test "the sidebar marks the current page", %{conn: conn} do
    stub_upstream_models(["qwen"])
    {:ok, lv, _html} = live(conn, ~p"/me/personas/new")
    assert lv |> element(".sidebar a.active", "Crew") |> has_element?()
    assert lv |> element(".sidebar .disabled", "MCPs") |> has_element?()
  end

  test "extensions show which of the user's crew use them", %{conn: conn, user: user} do
    clock = extension_fixture(nil, ~s(return { description = "Adds the current date and time." }))
    title = extension_fixture(nil, "return {}")
    persona_fixture(user, %{"name" => "Clock", "extensions" => %{clock.id => %{}}})
    persona_fixture(user_fixture(), %{"name" => "Theirs", "extensions" => %{title.id => %{}}})

    {:ok, lv, html} = live(conn, ~p"/me/extensions")
    assert html =~ "Adds the current date and time"
    assert lv |> element("#extensions a", "Clock") |> has_element?()
    refute html =~ "Theirs"
    assert lv |> element(".sidebar a.active", "Extensions") |> has_element?()
  end

  describe "skills" do
    test "global skills can be read, the user's own edited, others' not seen", %{
      conn: conn,
      user: user
    } do
      {:ok, global} =
        Meridian.Skills.create_skill(nil, %{
          "name" => "everyones",
          "description" => "For all.",
          "prompt" => "Global instructions."
        })

      {:ok, theirs} =
        Meridian.Skills.create_skill(user_fixture(), %{
          "name" => "theirs",
          "description" => "Not yours.",
          "prompt" => "x"
        })

      {:ok, lv, _html} = live(conn, ~p"/me/skills/new")

      {:ok, _lv, html} =
        lv
        |> form("#skill-form", skill: %{name: "mine", description: "Mine.", prompt: "My way."})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Skill saved."

      {:ok, lv, html} = live(conn, ~p"/me/skills")
      assert lv |> element("#skills tr", "everyones") |> render() =~ "global"
      assert lv |> element("#skills tr", "mine") |> render() =~ "yours"
      refute html =~ "theirs"

      {:ok, lv, _html} = live(conn, ~p"/me/skills/#{global}")
      refute has_element?(lv, "#skill-form")
      assert lv |> element("#skill-prompt") |> render() =~ "Global instructions."

      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/me/skills/#{theirs}") end

      [mine] = Enum.filter(Meridian.Skills.list_available(user), &(&1.name == "mine"))
      assert mine.user_id == user.id
    end
  end

  describe "extensions" do
    test "lists global extensions and the user's own, not anyone else's", %{
      conn: conn,
      user: user
    } do
      global = extension_fixture(nil, "return {}", %{"name" => "everyones"})
      mine = extension_fixture(user, "return {}", %{"name" => "mine"})
      theirs = extension_fixture(user_fixture(), "return {}", %{"name" => "theirs"})

      {:ok, lv, html} = live(conn, ~p"/me/extensions")
      assert lv |> element("#extensions tr", "everyones") |> render() =~ "global"
      assert lv |> element("#extensions tr", "mine") |> render() =~ "yours"
      refute html =~ "theirs"

      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/me/extensions/#{theirs}") end

      assert_raise Ecto.NoResultsError, fn ->
        get(conn, ~p"/me/extensions/#{theirs}/export")
      end

      # Global extensions can be read and exported, not edited.
      {:ok, lv, html} = live(conn, ~p"/me/extensions/#{global}")
      assert html =~ "A global extension"
      refute has_element?(lv, "#extension-form")
      assert lv |> element("#extension-source") |> render() =~ "return {}"
      assert get(conn, ~p"/me/extensions/#{global}/export") |> response(200) == "return {}"

      {:ok, lv, _html} = live(conn, ~p"/me/extensions/#{mine}")
      assert has_element?(lv, "#extension-form")
    end

    test "creating one makes it the user's own", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/me/extensions/new")

      {:ok, _lv, html} =
        lv
        |> form("#extension-form", extension: %{name: "mine", source: "return {}"})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Extension saved."
      assert [%{name: "mine"} = extension] = Meridian.Extensions.list_available(user)
      assert extension.user_id == user.id
    end
  end
end
