defmodule MeridianWeb.Api.AgentController do
  @moduledoc """
  `GET /api/agents`: the agents the caller may use. `id` is what threads take as `agent`;
  `default` marks the one a thread gets without one.
  """
  use MeridianWeb, :controller

  alias Meridian.Accounts.ApiKey.Policy
  alias Meridian.Agents
  alias Meridian.Agents.Agent

  def index(conn, _params) do
    %{current_user: user, current_policy: policy} = conn.assigns
    default = Agents.resolve_agent(user, policy, nil)

    data =
      for agent <- Agents.list_agents(user), Policy.allows?(policy, agent.slug) do
        %{
          id: Agent.model_id(agent),
          name: agent.name,
          model: agent.model,
          default: match?({:ok, %{id: id}} when id == agent.id, default)
        }
      end

    json(conn, %{data: data})
  end
end
