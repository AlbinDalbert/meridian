defmodule Meridian.AccessRequestsTest do
  use Meridian.DataCase, async: true

  import Meridian.Fixtures

  alias Meridian.{AccessRequests, Accounts, Agents}

  test "a request is recorded, and says the same whoever asks" do
    assert {:ok, :requested} =
             AccessRequests.request_access(%{"email" => " Bob@Example.com ", "name" => "Bob"})

    assert [%{email: "Bob@Example.com", name: "Bob", status: "pending", times_requested: 1}] =
             AccessRequests.list_requests("pending")

    # An email that already has a user isn't recorded at all.
    user_fixture(%{"email" => "ada@example.com"})
    assert {:ok, :requested} = AccessRequests.request_access(%{"email" => "ADA@example.com"})
    assert [_] = AccessRequests.list_requests("pending")
  end

  test "asking again moves the request to the top instead of adding another" do
    {:ok, :requested} = AccessRequests.request_access(%{"email" => "bob@example.com"})
    {:ok, :requested} = AccessRequests.request_access(%{"email" => "kim@example.com"})

    assert ["kim@example.com", "bob@example.com"] =
             Enum.map(AccessRequests.list_requests("pending"), & &1.email)

    {:ok, :requested} =
      AccessRequests.request_access(%{"email" => "BOB@example.com", "name" => "Bob"})

    assert [
             %{email: "bob@example.com", name: "Bob", times_requested: 2},
             %{email: "kim@example.com", times_requested: 1}
           ] = AccessRequests.list_requests("pending")

    # Asking again without a name keeps the one given before.
    {:ok, :requested} = AccessRequests.request_access(%{"email" => "bob@example.com"})
    assert [%{name: "Bob", times_requested: 3}, _] = AccessRequests.list_requests("pending")
  end

  test "the name is optional; the email must look like one" do
    assert {:ok, :requested} = AccessRequests.request_access(%{"email" => "x@y", "name" => "  "})
    assert [%{name: nil}] = AccessRequests.list_requests("pending")

    assert {:error, changeset} = AccessRequests.request_access(%{"email" => "nope"})
    assert %{email: ["must be a valid email address"]} = errors_on(changeset)
  end

  test "a rejected email asking again stays rejected until it's restored" do
    {:ok, :requested} = AccessRequests.request_access(%{"email" => "eve@example.com"})
    [request] = AccessRequests.list_requests("pending")
    {:ok, request} = AccessRequests.reject(request)

    {:ok, :requested} = AccessRequests.request_access(%{"email" => "eve@example.com"})
    assert AccessRequests.list_requests("pending") == []

    assert [%{status: "rejected", status_changed_at: %DateTime{}, times_requested: 2}] =
             AccessRequests.list_requests("rejected")

    {:ok, _} = AccessRequests.restore(request)
    assert [_] = AccessRequests.list_requests("pending")
  end

  test "snoozing moves a request out of the pending list, and asking again keeps it there" do
    {:ok, :requested} = AccessRequests.request_access(%{"email" => "sam@example.com"})
    [request] = AccessRequests.list_requests("pending")
    {:ok, _} = AccessRequests.snooze(request)

    assert AccessRequests.list_requests("pending") == []
    assert [%{email: "sam@example.com"}] = AccessRequests.list_requests("snoozed")

    {:ok, :requested} = AccessRequests.request_access(%{"email" => "sam@example.com"})
    assert [%{times_requested: 2}] = AccessRequests.list_requests("snoozed")
  end

  test "accepting creates the user with a default agent and removes the request" do
    {:ok, :requested} = AccessRequests.request_access(%{"email" => "kim@example.com"})

    {:ok, :requested} =
      AccessRequests.request_access(%{"email" => "lee@example.com", "name" => "Lee"})

    [lee, kim] = AccessRequests.list_requests("pending")

    assert {:ok, user} = AccessRequests.accept(kim, %{"model" => "qwen"}, force: true)
    assert %{name: "kim", email: "kim@example.com"} = user
    assert %{model: "qwen"} = Agents.get_default_agent(user)

    assert {:ok, %{name: "Lee"}} = AccessRequests.accept(lee, %{"model" => "qwen"}, force: true)
    assert AccessRequests.list_requests("pending") == []
    assert Agents.newest_default_model() == "qwen"
  end

  test "a failed accept keeps the request" do
    {:ok, :requested} = AccessRequests.request_access(%{"email" => "kim@example.com"})
    [request] = AccessRequests.list_requests("pending")

    assert {:error, :agent, _changeset} = AccessRequests.accept(request, %{"model" => ""})

    # Someone added them by hand in the meantime.
    user_fixture(%{"email" => "kim@example.com"})

    assert {:error, :user, _changeset} =
             AccessRequests.accept(request, %{"model" => "m"}, force: true)

    assert [_] = AccessRequests.list_requests("pending")
    assert [_] = Accounts.list_users() |> Enum.filter(&(&1.email == "kim@example.com"))
  end
end
