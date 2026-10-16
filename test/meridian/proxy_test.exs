defmodule Meridian.ProxyTest do
  use Meridian.DataCase, async: true

  import Meridian.Fixtures

  alias Meridian.Accounts.ApiKey.Policy
  alias Meridian.{Personas, Proxy}
  alias Meridian.Personas.Persona

  setup do
    user = user_fixture()
    coder = persona_fixture(user, %{"slug" => "coder"})
    %{user: user, default: Personas.get_default_persona(user), coder: coder}
  end

  describe "resolve_model/3" do
    test "resolves meridian/<slug> to the persona", %{user: user, coder: coder} do
      assert {:ok, {:persona, %Persona{id: id}}} =
               Proxy.resolve_model(user, %Policy{}, "meridian/coder")

      assert id == coder.id
    end

    test "unknown meridian/ personas are not found", %{user: user} do
      assert {:error, :model_not_found} = Proxy.resolve_model(user, %Policy{}, "meridian/nope")
    end

    test "other models fall back to the user's default persona", %{user: user, default: default} do
      for model <- ["gpt-4o", nil] do
        assert {:ok, {:persona, %Persona{id: id}}} = Proxy.resolve_model(user, %Policy{}, model)
        assert id == default.id
      end
    end

    test "the policy's default persona takes precedence", %{user: user, coder: coder} do
      policy = %Policy{default_persona: "coder"}
      assert {:ok, {:persona, %Persona{id: id}}} = Proxy.resolve_model(user, policy, "gpt-4o")
      assert id == coder.id
    end

    test "the policy restricts personas", %{user: user, coder: coder} do
      policy = %Policy{allowed_personas: ["coder"]}

      assert {:error, :model_not_found} = Proxy.resolve_model(user, policy, "meridian/default")
      # The user's default persona isn't allowed either.
      assert {:error, :model_not_found} = Proxy.resolve_model(user, policy, "gpt-4o")

      assert {:ok, {:persona, %Persona{id: id}}} =
               Proxy.resolve_model(user, policy, "meridian/coder")

      assert id == coder.id
    end

    test "personas of other users are not found", %{coder: _coder} do
      other = user_fixture()
      assert {:error, :model_not_found} = Proxy.resolve_model(other, %Policy{}, "meridian/coder")
    end
  end

  describe "build_request/2" do
    setup %{coder: coder} do
      {:ok, coder} =
        Personas.update_persona(
          coder,
          %{
            "model" => "qwen",
            "system_prompt" => "You are terse.",
            "params" => %{"temperature" => 0.2, "max_tokens" => 100}
          },
          force: true
        )

      %{coder: coder}
    end

    test "applies the model, params, and system prompt", %{coder: coder} do
      body = %{
        "model" => "meridian/coder",
        "temperature" => 0.9,
        "messages" => [%{"role" => "user", "content" => "hi"}]
      }

      assert Proxy.build_request({:persona, coder}, body) == %{
               "model" => "qwen",
               "temperature" => 0.9,
               "max_tokens" => 100,
               "messages" => [
                 %{"role" => "system", "content" => "You are terse."},
                 %{"role" => "user", "content" => "hi"}
               ]
             }
    end

    test "merges into the client's leading system message", %{coder: coder} do
      messages = [
        %{"role" => "system", "content" => "Use tools."},
        %{"role" => "user", "content" => "hi"}
      ]

      assert %{
               "messages" => [
                 %{"role" => "system", "content" => "You are terse.\n\nUse tools."},
                 _
               ]
             } =
               Proxy.build_request({:persona, coder}, %{"messages" => messages})

      parts = [%{"type" => "text", "text" => "Use tools."}]

      assert %{
               "messages" => [
                 %{"role" => "developer", "content" => [%{"text" => "You are terse."}, _]}
               ]
             } =
               Proxy.build_request({:persona, coder}, %{
                 "messages" => [%{"role" => "developer", "content" => parts}]
               })
    end

    test "leaves messages alone without a system prompt", %{default: default} do
      messages = [%{"role" => "user", "content" => "hi"}]

      assert %{"messages" => ^messages} =
               Proxy.build_request({:persona, default}, %{"messages" => messages})
    end

    test "passes raw upstream models through" do
      body = %{"model" => "qwen", "messages" => []}
      assert Proxy.build_request({:upstream, "qwen"}, body) == body
    end
  end
end
