defmodule Meridian.PersonasTest do
  use Meridian.DataCase, async: true

  import Meridian.Fixtures

  alias Meridian.Personas

  setup do
    %{user: user_fixture()}
  end

  describe "create_persona/3 model validation" do
    test "accepts a model the upstream lists", %{user: user} do
      stub_upstream_models(["m1", "m2"])

      assert {:ok, persona} =
               Personas.create_persona(user, %{
                 "slug" => "coder",
                 "name" => "Coder",
                 "model" => "m2"
               })

      assert persona.model == "m2"
    end

    test "rejects a model the upstream doesn't list", %{user: user} do
      stub_upstream_models(["m1"])

      assert {:error, changeset} =
               Personas.create_persona(user, %{
                 "slug" => "coder",
                 "name" => "Coder",
                 "model" => "m2"
               })

      assert "is not offered by the upstream" in errors_on(changeset).model
    end

    test "reports an unreachable upstream", %{user: user} do
      stub_upstream_down()

      assert {:error, changeset} =
               Personas.create_persona(user, %{
                 "slug" => "coder",
                 "name" => "Coder",
                 "model" => "m2"
               })

      assert "can't be validated: upstream unreachable" in errors_on(changeset).model
    end

    test "force: true skips validation", %{user: user} do
      stub_upstream_down()

      assert {:ok, _persona} =
               Personas.create_persona(
                 user,
                 %{"slug" => "coder", "name" => "Coder", "model" => "m2"},
                 force: true
               )
    end

    test "updates only validate a changed model", %{user: user} do
      persona = persona_fixture(user, %{"model" => "unlisted"})
      stub_upstream_down()

      assert {:ok, persona} = Personas.update_persona(persona, %{"name" => "Renamed"})
      assert persona.name == "Renamed"
    end
  end

  test "slugs are validated and unique per user", %{user: user} do
    assert {:error, changeset} =
             Personas.create_persona(user, %{"slug" => "Bad Slug", "name" => "x", "model" => "m"},
               force: true
             )

    assert %{slug: [_]} = errors_on(changeset)

    assert {:error, changeset} =
             Personas.create_persona(user, %{"slug" => "default", "name" => "x", "model" => "m"},
               force: true
             )

    assert "has already been taken" in errors_on(changeset).slug

    other = user_fixture()

    assert {:ok, _} =
             Personas.create_persona(other, %{"slug" => "coder", "name" => "x", "model" => "m"},
               force: true
             )

    assert {:ok, _} =
             Personas.create_persona(user, %{"slug" => "coder", "name" => "x", "model" => "m"},
               force: true
             )
  end

  test "params must not override model or messages", %{user: user} do
    assert {:error, changeset} =
             Personas.create_persona(
               user,
               %{"slug" => "p", "name" => "x", "model" => "m", "params" => %{"model" => "other"}},
               force: true
             )

    assert %{params: [_]} = errors_on(changeset)
  end

  test "make_default/1 moves the default", %{user: user} do
    old_default = Personas.get_default_persona(user)
    persona = persona_fixture(user)

    assert {:ok, _} = Personas.make_default(persona)
    assert Personas.get_default_persona(user).id == persona.id
    refute Personas.get_persona!(old_default.id).is_default
  end

  test "the default persona can't be deleted", %{user: user} do
    assert {:error, :default_persona} =
             user |> Personas.get_default_persona() |> Personas.delete_persona()

    assert {:ok, _} = user |> persona_fixture() |> Personas.delete_persona()
  end
end
