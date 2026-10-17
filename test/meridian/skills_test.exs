defmodule Meridian.SkillsTest do
  use Meridian.DataCase, async: true
  use Oban.Testing, repo: Meridian.Repo

  import Meridian.Fixtures

  @moduletag :capture_log

  alias Meridian.{Agents, Runs, Skills}
  alias Meridian.Runs.Worker

  setup do
    user = user_fixture(%{}, %{"model" => "qwen", "system_prompt" => "Be brief."})
    %{user: user, agent: Agents.get_default_agent(user)}
  end

  defp skill_fixture(owner, attrs) do
    {:ok, skill} =
      Skills.create_skill(
        owner,
        Map.merge(
          %{
            "name" => unique_name("skill"),
            "description" => "Does things.",
            "prompt" => "Do it."
          },
          attrs
        )
      )

    skill
  end

  defp enable(agent, skills) do
    {:ok, agent} = Agents.update_agent(agent, %{"skills" => Enum.map(skills, & &1.id)})
    agent
  end

  test "skills are checked when saved" do
    assert {:error, changeset} = Skills.create_skill(nil, %{"name" => "Bad Name"})

    assert %{
             name: ["must be lowercase letters, digits, '-' or '_'"],
             description: ["can't be blank"],
             prompt: ["can't be blank"]
           } = errors_on(changeset)

    skill = skill_fixture(nil, %{"name" => "sql"})
    assert {:error, changeset} = Skills.update_skill(skill, %{"description" => " "})
    assert errors_on(changeset).description == ["can't be blank"]

    assert {:error, changeset} =
             Skills.create_skill(nil, %{"name" => "sql", "description" => "x", "prompt" => "y"})

    assert errors_on(changeset).name == ["has already been taken"]
  end

  test "an agent gets the skills it enables that its user can use", %{
    user: user,
    agent: agent
  } do
    global = skill_fixture(nil, %{"name" => "sql"})
    own = skill_fixture(user, %{"name" => "sql", "prompt" => "My way."})
    other = skill_fixture(user_fixture(), %{"name" => "theirs"})
    unused = skill_fixture(nil, %{"name" => "unused"})

    agent = enable(agent, [global, own, other])

    # The user's own shadows the global one with the same name; someone else's is ignored.
    assert [%{id: id}] = Skills.enabled(agent)
    assert id == own.id

    assert Enum.map(Skills.list_available(user), & &1.id) |> Enum.sort() ==
             Enum.sort([global.id, own.id, unused.id])

    # Ids of skills that are gone are kept on the agent.
    {:ok, _} = Skills.delete_skill(own)
    agent = Agents.get_agent!(agent.id)
    assert own.id in agent.skills
    assert Enum.map(Skills.enabled(agent), & &1.id) == [global.id]
  end

  test "recommended extensions that an agent doesn't enable", %{user: user} do
    curl = extension_fixture(nil, "return {}")
    other = extension_fixture(user_fixture(), "return {}")
    skill = skill_fixture(nil, %{"recommended_extensions" => [curl.id, other.id]})

    assert Skills.missing_extensions(skill, [curl.id, other.id], user) == []

    assert Skills.missing_extensions(skill, [], user) == [
             %{id: curl.id, name: curl.name},
             %{id: other.id, name: nil}
           ]
  end

  test "a run lists the skills, and the model loads one with load_skill", %{
    user: user,
    agent: agent
  } do
    sql =
      skill_fixture(nil, %{
        "name" => "sql",
        "description" => "Querying databases.",
        "prompt" => "Use read-only queries."
      })

    enable(agent, [sql, skill_fixture(nil, %{"name" => "maps"})])

    thread = thread_fixture(user)
    {_message, run} = message_fixture(thread, "How many users?")

    stub_upstream_streams([
      tool_call_events([{"c1", "load_skill", ~s({"name": "sql"})}]),
      completion_events(["Done."])
    ])

    :ok = perform_job(Worker, %{"run_id" => run.id})
    assert Runs.get_run!(run.id).status == :completed

    assert_received {:upstream_request, first}
    assert_received {:upstream_request, second}

    assert [%{"role" => "system", "content" => system} | _] = first["messages"]
    assert system =~ ~r/^Be brief\.\n\nYou have skills/
    assert system =~ "- maps: Does things.\n- sql: Querying databases."

    assert [%{"function" => %{"name" => "load_skill", "parameters" => parameters}}] =
             first["tools"]

    assert parameters["properties"]["name"]["enum"] == ["maps", "sql"]

    assert [%{"content" => "Use read-only queries."}] =
             Enum.filter(second["messages"], &(&1["role"] == "tool"))
  end

  test "without skills, there's no section and no tool", %{user: user} do
    thread = thread_fixture(user)
    {_message, run} = message_fixture(thread)
    stub_upstream_stream(completion_events(["Hi"]))
    :ok = perform_job(Worker, %{"run_id" => run.id})

    assert_received {:upstream_request, request}
    refute Map.has_key?(request, "tools")
    assert [%{"role" => "system", "content" => "Be brief."} | _] = request["messages"]
  end
end
