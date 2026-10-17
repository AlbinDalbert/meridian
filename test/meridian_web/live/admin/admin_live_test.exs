defmodule MeridianWeb.Admin.AdminLiveTest do
  use MeridianWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Meridian.Fixtures

  alias Meridian.{Accounts, Agents}

  setup :log_in_admin

  test "LiveViews require an admin session" do
    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(build_conn(), ~p"/admin/users")
  end

  test "creating a user creates their default agent", %{conn: conn} do
    stub_upstream_models(["qwen", "llama"])
    {:ok, lv, html} = live(conn, ~p"/admin/users/new")
    assert html =~ "Default agent"

    assert lv
           |> form("#user-form",
             user: %{name: "Ada", email: "ada@example.com"},
             agent: %{model: "nope"}
           )
           |> render_submit() =~ "is not offered by the upstream"

    {:ok, _lv, html} =
      lv
      |> form("#user-form",
        user: %{name: "Ada", email: "ada@example.com"},
        agent: %{model: "qwen"}
      )
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "User created."
    assert html =~ "meridian/default"
    assert [%{name: "Ada"} = user] = Accounts.list_users()
    assert %{model: "qwen"} = Agents.get_default_agent(user)
  end

  test "minting a key shows the token once", %{conn: conn} do
    user = user_fixture()
    {:ok, lv, _html} = live(conn, ~p"/admin/users/#{user}/keys/new")

    html =
      lv
      |> form("#api-key-form", api_key: %{name: "laptop", policy: %{default_agent: "default"}})
      |> render_submit()

    assert [api_key] = Accounts.list_api_keys(user)
    assert %{name: "laptop", policy: %{default_agent: "default"}} = api_key

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

  test "unlinking a user's sign-in", %{conn: conn} do
    user =
      user_fixture()
      |> Ecto.Changeset.change(oidc_issuer: "https://auth.test", oidc_subject: "user_ada")
      |> Meridian.Repo.update!()

    {:ok, lv, html} = live(conn, ~p"/admin/users/#{user}")
    assert html =~ "user_ada"

    assert lv |> element("button", "Unlink") |> render_click() =~ "Sign-in unlinked."
    assert %{oidc_subject: nil, oidc_issuer: nil} = Accounts.get_user!(user.id)
  end

  test "creating and editing an agent", %{conn: conn} do
    user = user_fixture()
    stub_upstream_down()
    {:ok, lv, _html} = live(conn, ~p"/admin/users/#{user}/agents/new")

    attrs = %{slug: "coder", name: "Coder", model: "qwen", params: ~s({"temperature": 0.2})}

    assert lv |> form("#agent-form", agent: attrs) |> render_submit() =~
             "upstream unreachable"

    assert lv
           |> form("#agent-form", agent: %{attrs | params: "nope"}, force: "true")
           |> render_submit() =~
             "is invalid"

    {:ok, _lv, html} =
      lv
      |> form("#agent-form", agent: attrs, force: "true")
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "meridian/coder"
    agent = Agents.get_agent_by_slug(user, "coder")
    assert agent.params == %{"temperature" => 0.2}

    {:ok, lv, html} = live(conn, ~p"/admin/agents/#{agent}/edit")
    assert html =~ "temperature"

    {:ok, _lv, _html} =
      lv
      |> form("#agent-form", agent: %{system_prompt: "Be terse."})
      |> render_submit()
      |> follow_redirect(conn)

    assert Agents.get_agent!(agent.id).system_prompt == "Be terse."
  end

  test "default params and model validation are folded into an advanced section", %{conn: conn} do
    user = user_fixture()
    stub_upstream_models(["upstream-model"])
    agent = Agents.get_default_agent(user)
    {:ok, lv, _html} = live(conn, ~p"/admin/agents/#{agent}/edit")

    assert has_element?(lv, "#agent-advanced:not([open]) #agent_params")
    assert has_element?(lv, "#agent-advanced #force")

    lv |> element("#agent-advanced summary") |> render_click()
    assert has_element?(lv, "#agent-advanced[open]")
    lv |> element("#agent-advanced summary") |> render_click()
    refute has_element?(lv, "#agent-advanced[open]")

    # An invalid param opens it, so the error can be seen.
    assert lv |> form("#agent-form", agent: %{params: "nope"}) |> render_change() =~
             "is invalid"

    assert has_element?(lv, "#agent-advanced[open]")

    # Once params are set, the summary says so.
    {:ok, _} = Agents.update_agent(agent, %{"params" => %{"temperature" => 0.2}})
    {:ok, lv, _html} = live(conn, ~p"/admin/agents/#{agent}/edit")
    assert lv |> element("#agent-advanced summary") |> render() =~ "1 default param<"
  end

  @clock """
  return {
    description = "Tells the time.",
    settings = { timezone = "Etc/UTC" },
    validate = function(settings)
      if not meridian.now(settings.timezone) then return "unknown timezone" end
    end,
  }
  """

  test "enabling and configuring extensions on an agent", %{conn: conn} do
    user = user_fixture()
    stub_upstream_models(["upstream-model"])
    agent = Agents.get_default_agent(user)
    clock = extension_fixture(nil, @clock, %{"name" => "clock"})
    own = extension_fixture(user, "return {}", %{"name" => "theirs"})
    other = extension_fixture(user_fixture(), "return {}", %{"name" => "someone-elses"})
    gone = Ecto.UUID.generate()

    {:ok, _agent} = Agents.update_agent(agent, %{"extensions" => %{gone => %{"x" => 1}}})

    {:ok, lv, html} = live(conn, ~p"/admin/agents/#{agent}/edit")
    assert html =~ "Settings for 1 extension that&#39;s gone (kept, but ignored)."
    assert html =~ "theirs (own)"
    refute html =~ other.name
    refute has_element?(lv, "#extension-#{clock.id}-settings")

    # Switching an extension on shows its settings, with the defaults filled in.
    lv
    |> form("#agent-form", extensions: %{clock.id => %{enabled: "true"}})
    |> render_change()

    assert lv |> element("#extension-#{clock.id}-settings") |> render() =~ "Etc/UTC"

    assert lv
           |> form("#agent-form",
             extensions: %{clock.id => %{enabled: "true", settings: ~s({"timezone": "Nowhere"})}}
           )
           |> render_submit() =~ "clock: unknown timezone"

    {:ok, _lv, _html} =
      lv
      |> form("#agent-form",
        extensions: %{
          clock.id => %{enabled: "true", settings: ~s({"timezone": "Europe/Stockholm"})},
          own.id => %{enabled: "true"}
        }
      )
      |> render_submit()
      |> follow_redirect(conn)

    assert Agents.get_agent!(agent.id).extensions == %{
             clock.id => %{"timezone" => "Europe/Stockholm"},
             own.id => %{},
             gone => %{"x" => 1}
           }
  end

  describe "skills" do
    test "creating a global skill that recommends extensions", %{conn: conn} do
      curl = extension_fixture(nil, "return {}", %{"name" => "curl"})
      extension_fixture(user_fixture(), "return {}", %{"name" => "users-own"})

      {:ok, lv, html} = live(conn, ~p"/admin/skills/new")
      # A global skill can only recommend global extensions.
      assert html =~ "curl"
      refute html =~ "users-own"

      assert lv
             |> form("#skill-form", skill: %{name: "Bad", description: "", prompt: ""})
             |> render_submit() =~ "can&#39;t be blank"

      {:ok, _lv, html} =
        lv
        |> form("#skill-form",
          skill: %{
            name: "db-fetching",
            description: "Fetching data.",
            prompt: "Use curl.",
            recommended_extensions: [curl.id]
          }
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Skill saved."
      assert [skill] = Meridian.Skills.list_skills()
      assert skill.recommended_extensions == [curl.id]
      assert skill.user_id == nil

      {:ok, lv, _html} = live(conn, ~p"/admin/skills")
      assert lv |> element("#skills tr", "db-fetching") |> render() =~ "0 agents"
      assert lv |> element(".sidebar a.active", "Skills") |> has_element?()
    end

    test "the agent form warns about a skill's missing extensions", %{conn: conn} do
      user = user_fixture()
      stub_upstream_models(["upstream-model"])
      agent = Agents.get_default_agent(user)
      curl = extension_fixture(nil, "return {}", %{"name" => "curl"})

      {:ok, skill} =
        Meridian.Skills.create_skill(nil, %{
          "name" => "db-fetching",
          "description" => "Fetching data.",
          "prompt" => "Use curl.",
          "recommended_extensions" => [curl.id]
        })

      {:ok, lv, _html} = live(conn, ~p"/admin/agents/#{agent}/edit")
      refute has_element?(lv, "#skill-#{skill.id}-warning")

      lv |> form("#agent-form", skills: %{skill.id => "true"}) |> render_change()

      assert lv |> element("#skill-#{skill.id}-warning") |> render() =~
               "Works best with curl, which isn&#39;t on for this agent."

      lv
      |> form("#agent-form",
        skills: %{skill.id => "true"},
        extensions: %{curl.id => %{enabled: "true"}}
      )
      |> render_change()

      refute has_element?(lv, "#skill-#{skill.id}-warning")

      # The warning doesn't stop saving.
      {:ok, _lv, _html} =
        lv
        |> form("#agent-form",
          skills: %{skill.id => "true"},
          extensions: %{curl.id => %{enabled: "false"}}
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert Agents.get_agent!(agent.id).skills == [skill.id]
    end
  end

  test "making an agent the default and deleting agents", %{conn: conn} do
    user = user_fixture()
    agent = agent_fixture(user, %{"slug" => "coder"})
    {:ok, lv, _html} = live(conn, ~p"/admin/users/#{user}")

    lv |> element("#agents button", "Make default") |> render_click()
    assert Agents.get_default_agent(user).id == agent.id

    lv |> element("#agents button", "Delete") |> render_click()
    assert Agents.get_agent_by_slug(user, "default") == nil
  end

  test "the agents page lists every user's agents", %{conn: conn} do
    ada = user_fixture(%{"name" => "Ada"})
    clock = extension_fixture(nil, "return {}", %{"name" => "clock"})
    agent_fixture(ada, %{"slug" => "coder", "extensions" => %{clock.id => %{}}})
    agent_fixture(user_fixture(%{"name" => "Bob"}), %{"slug" => "writer"})

    {:ok, lv, html} = live(conn, ~p"/admin/agents")
    assert html =~ "meridian/coder"
    assert html =~ "meridian/writer"
    assert lv |> element("#agents a", "Ada") |> has_element?()
    assert lv |> element(".sidebar a.active", "Agents") |> has_element?()
    assert lv |> element("#agents tr", "meridian/coder") |> render() =~ "clock"
  end

  test "the extensions page lists every extension", %{conn: conn} do
    user = user_fixture(%{"name" => "Ada"})
    clock = extension_fixture(nil, @clock, %{"name" => "clock"})
    extension_fixture(nil, "return {}", %{"name" => "unused"})
    extension_fixture(user, "return {}", %{"name" => "adas"})
    agent_fixture(user, %{"extensions" => %{clock.id => %{}}})
    agent_fixture(user, %{"extensions" => %{clock.id => %{}}})

    {:ok, lv, _html} = live(conn, ~p"/admin/extensions")
    assert lv |> element("#extensions tr", "clock") |> render() =~ "2 agents"
    assert lv |> element("#extensions tr", "clock") |> render() =~ "Tells the time."
    assert lv |> element("#extensions tr", "clock") |> render() =~ "global"
    assert lv |> element("#extensions tr", "unused") |> render() =~ "0 agents"
    assert lv |> element("#extensions tr", "adas") |> render() =~ "Ada"
  end

  describe "the extension editor" do
    test "creates global extensions, and refuses broken scripts", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/admin/extensions/new")
      # New extensions start from a template.
      assert html =~ "function M.before_run"

      assert lv
             |> form("#extension-form", extension: %{name: "hello", source: "return 1"})
             |> render_submit() =~ "the script must return a table"

      {:ok, _lv, html} =
        lv
        |> form("#extension-form", extension: %{name: "hello", source: @clock})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Extension saved."
      assert [%{name: "hello", user_id: nil}] = Meridian.Extensions.list_extensions()
    end

    test "edits any extension, shows its latest error, and deletes it", %{conn: conn} do
      user = user_fixture()
      extension = extension_fixture(user, "return {}", %{"name" => "users-own"})

      {:ok, lv, html} = live(conn, ~p"/admin/extensions/#{extension}")
      assert html =~ "Belongs to"
      refute has_element?(lv, "#extension-error")

      send(
        lv.pid,
        {:extension_error, extension.id,
         %{where: "run_end", message: "boom", at: DateTime.utc_now()}}
      )

      assert lv |> element("#extension-error") |> render() =~ "boom"

      {:ok, lv, _html} =
        lv
        |> form("#extension-form", extension: %{source: "return { description = \"New\" }"})
        |> render_submit()
        |> follow_redirect(conn)

      assert Meridian.Extensions.description(Meridian.Extensions.get_extension!(extension.id)) ==
               "New"

      {:ok, _lv, html} =
        lv |> element("button", "Delete") |> render_click() |> follow_redirect(conn)

      assert html =~ "Extension deleted."
      assert Meridian.Extensions.get_extension(extension.id) == nil
    end

    test "shows the tools a script offers", %{conn: conn} do
      extension =
        extension_fixture(nil, """
        return { tools = { roll = { description = "Rolls a die.", run = function() end } } }
        """)

      {:ok, lv, _html} = live(conn, ~p"/admin/extensions/#{extension}")
      assert lv |> element("#extension-tools") |> render() =~ "Rolls a die."

      {:ok, lv, _html} = live(conn, ~p"/admin/extensions/#{extension_fixture(nil, "return {}")}")
      refute has_element?(lv, "#extension-tools")
    end

    test "imports a script from a file into the editor", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/extensions/new")
      lv |> form("#extension-form", extension: %{name: ""}) |> render_change()

      script =
        file_input(lv, "#extension-form", :script, [
          %{name: "My Clock.lua", content: @clock, type: "text/plain"}
        ])

      render_upload(script, "My Clock.lua")
      assert lv |> element("#extension_name") |> render() =~ ~s(value="my-clock")
      assert lv |> element("#extension_source") |> render() =~ "Tells the time."
      # Only imported: nothing is saved until it's saved.
      assert Meridian.Extensions.list_extensions() == []
    end

    test "exports a script", %{conn: conn} do
      extension = extension_fixture(nil, @clock, %{"name" => "clock"})
      conn = get(conn, ~p"/admin/extensions/#{extension}/export")
      assert response(conn, 200) == @clock

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="clock.lua")
             ]
    end
  end
end
