defmodule Meridian.AccountsTest do
  use Meridian.DataCase, async: true

  import Meridian.Fixtures

  alias Meridian.{Accounts, Personas}
  alias Meridian.Accounts.ApiKey

  describe "create_user/3" do
    test "creates the user with a default persona" do
      assert {:ok, user} =
               Accounts.create_user(
                 %{"name" => "Ada", "email" => "ada@example.com"},
                 %{"model" => "m1"},
                 force: true
               )

      assert [persona] = Personas.list_personas(user)
      assert %{slug: "default", model: "m1", is_default: true} = persona
    end

    test "validates the default persona's model against the upstream" do
      stub_upstream_models(["m1"])

      assert {:error, :persona, changeset} =
               Accounts.create_user(%{"name" => "Ada", "email" => "ada@example.com"}, %{
                 "model" => "nope"
               })

      assert "is not offered by the upstream" in errors_on(changeset).model
      assert Accounts.list_users() == []

      assert {:ok, _user} =
               Accounts.create_user(%{"name" => "Ada", "email" => "ada@example.com"}, %{
                 "model" => "m1"
               })
    end

    test "returns user errors" do
      assert {:error, :user, changeset} =
               Accounts.create_user(%{"name" => "", "email" => "nope"}, %{"model" => "m"},
                 force: true
               )

      assert %{name: ["can't be blank"], email: [_]} = errors_on(changeset)
    end

    test "email is required" do
      assert {:error, :user, changeset} =
               Accounts.create_user(%{"name" => "Ada", "email" => " "}, %{"model" => "m"},
                 force: true
               )

      assert "can't be blank" in errors_on(changeset).email
    end

    test "emails are unique, case-insensitively" do
      user_fixture(%{"email" => "ada@example.com"})

      assert {:error, :user, changeset} =
               Accounts.create_user(
                 %{"name" => "Ada", "email" => "ADA@example.com"},
                 %{"model" => "m"},
                 force: true
               )

      assert "has already been taken" in errors_on(changeset).email
    end
  end

  test "delete_user/1 removes the user's keys and personas" do
    user = user_fixture()
    api_key = api_key_fixture(user)

    assert {:ok, _} = Accounts.delete_user(user)
    assert Personas.list_personas(user) == []
    assert Accounts.authenticate_api_key(api_key.token) == :error
  end

  describe "API keys" do
    test "mint_api_key/2 returns the token once and stores only its hash" do
      user = user_fixture()
      api_key = api_key_fixture(user)

      assert "mrd_" <> _ = api_key.token
      assert String.starts_with?(api_key.token, api_key.prefix)

      stored = Repo.get!(ApiKey, api_key.id)
      assert stored.token == nil
      assert stored.token_hash == :crypto.hash(:sha256, api_key.token)
    end

    test "authenticate_api_key/1 accepts active keys and records use" do
      user = user_fixture()
      api_key = api_key_fixture(user)

      assert {:ok, authenticated} = Accounts.authenticate_api_key(api_key.token)
      assert authenticated.id == api_key.id
      assert authenticated.user.id == user.id
      assert Repo.get!(ApiKey, api_key.id).last_used_at
    end

    test "authenticate_api_key/1 rejects unknown and revoked keys" do
      user = user_fixture()
      api_key = api_key_fixture(user)

      assert Accounts.authenticate_api_key("mrd_unknown") == :error
      assert Accounts.authenticate_api_key("not-a-key") == :error

      {:ok, _} = Accounts.revoke_api_key(api_key)
      assert Accounts.authenticate_api_key(api_key.token) == :error
    end

    test "policy defaults to all personas" do
      api_key = api_key_fixture(user_fixture())
      assert %{default_persona: nil, allowed_personas: []} = api_key.policy
    end

    test "policy default persona must be allowed" do
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.mint_api_key(user, %{
                 "name" => "k",
                 "policy" => %{"default_persona" => "a", "allowed_personas" => ["b", ""]}
               })

      assert %{policy: %{default_persona: ["must be one of the allowed personas"]}} =
               errors_on(changeset)

      assert {:ok, api_key} =
               Accounts.mint_api_key(user, %{
                 "name" => "k",
                 "policy" => %{"default_persona" => "b", "allowed_personas" => ["b", ""]}
               })

      assert %{default_persona: "b", allowed_personas: ["b"]} = api_key.policy
    end
  end
end
