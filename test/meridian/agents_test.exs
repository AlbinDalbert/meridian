defmodule Meridian.AgentsTest do
  use Meridian.DataCase, async: true

  import Meridian.Fixtures

  alias Meridian.Agents

  setup do
    %{user: user_fixture()}
  end

  test "slug, name, and model can't be blank, even when trimmed to nothing", %{user: user} do
    assert {:error, changeset} =
             Agents.create_agent(user, %{"slug" => " ", "name" => "", "model" => "  "},
               force: true
             )

    errors = errors_on(changeset)
    for field <- [:slug, :name, :model], do: assert("can't be blank" in errors[field])
  end

  describe "create_agent/3 model validation" do
    test "accepts a model the upstream lists", %{user: user} do
      stub_upstream_models(["m1", "m2"])

      assert {:ok, agent} =
               Agents.create_agent(user, %{
                 "slug" => "coder",
                 "name" => "Coder",
                 "model" => "m2"
               })

      assert agent.model == "m2"
    end

    test "rejects a model the upstream doesn't list", %{user: user} do
      stub_upstream_models(["m1"])

      assert {:error, changeset} =
               Agents.create_agent(user, %{
                 "slug" => "coder",
                 "name" => "Coder",
                 "model" => "m2"
               })

      assert "is not offered by the upstream" in errors_on(changeset).model
    end

    test "reports an unreachable upstream", %{user: user} do
      stub_upstream_down()

      assert {:error, changeset} =
               Agents.create_agent(user, %{
                 "slug" => "coder",
                 "name" => "Coder",
                 "model" => "m2"
               })

      assert "can't be validated: upstream unreachable" in errors_on(changeset).model
    end

    test "force: true skips validation", %{user: user} do
      stub_upstream_down()

      assert {:ok, _agent} =
               Agents.create_agent(
                 user,
                 %{"slug" => "coder", "name" => "Coder", "model" => "m2"},
                 force: true
               )
    end

    test "updates only validate a changed model", %{user: user} do
      agent = agent_fixture(user, %{"model" => "unlisted"})
      stub_upstream_down()

      assert {:ok, agent} = Agents.update_agent(agent, %{"name" => "Renamed"})
      assert agent.name == "Renamed"
    end
  end

  test "slugs are validated and unique per user", %{user: user} do
    assert {:error, changeset} =
             Agents.create_agent(user, %{"slug" => "Bad Slug", "name" => "x", "model" => "m"},
               force: true
             )

    assert %{slug: [_]} = errors_on(changeset)

    assert {:error, changeset} =
             Agents.create_agent(user, %{"slug" => "default", "name" => "x", "model" => "m"},
               force: true
             )

    assert "has already been taken" in errors_on(changeset).slug

    other = user_fixture()

    assert {:ok, _} =
             Agents.create_agent(other, %{"slug" => "coder", "name" => "x", "model" => "m"},
               force: true
             )

    assert {:ok, _} =
             Agents.create_agent(user, %{"slug" => "coder", "name" => "x", "model" => "m"},
               force: true
             )
  end

  test "params must not override model or messages", %{user: user} do
    assert {:error, changeset} =
             Agents.create_agent(
               user,
               %{"slug" => "p", "name" => "x", "model" => "m", "params" => %{"model" => "other"}},
               force: true
             )

    assert %{params: [_]} = errors_on(changeset)
  end

  test "make_default/1 moves the default", %{user: user} do
    old_default = Agents.get_default_agent(user)
    agent = agent_fixture(user)

    assert {:ok, _} = Agents.make_default(agent)
    assert Agents.get_default_agent(user).id == agent.id
    refute Agents.get_agent!(old_default.id).is_default
  end

  test "the default agent can't be deleted", %{user: user} do
    assert {:error, :default_agent} =
             user |> Agents.get_default_agent() |> Agents.delete_agent()

    assert {:ok, _} = user |> agent_fixture() |> Agents.delete_agent()
  end
end
