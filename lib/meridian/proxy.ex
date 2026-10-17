defmodule Meridian.Proxy do
  @moduledoc """
  The stateless, OpenAI-compatible surface (`/v1/*`): an agent-aware proxy.

  The client owns the conversation and the tool loop. Meridian resolves the requested model to
  an agent, applies the agent's system prompt, upstream model, and default params, and
  forwards everything else to the upstream unchanged.
  """
  require Logger

  alias Meridian.Accounts.ApiKey.Policy
  alias Meridian.Accounts.User
  alias Meridian.Agents
  alias Meridian.Agents.Agent
  alias Meridian.Upstream

  @type model :: {:agent, Agent.t()} | {:upstream, String.t()}

  @doc """
  The models a key can use: the user's agents the policy allows, plus the raw upstream models
  if `EXPOSE_UPSTREAM_MODELS` is enabled.
  """
  @spec list_models(User.t(), Policy.t()) :: [model()]
  def list_models(%User{} = user, %Policy{} = policy) do
    agents =
      for agent <- Agents.list_agents(user), Policy.allows?(policy, agent.slug) do
        {:agent, agent}
      end

    agents ++ upstream_models()
  end

  defp upstream_models do
    if expose_upstream_models?() do
      case Upstream.list_models() do
        {:ok, ids} ->
          for id <- ids, do: {:upstream, id}

        {:error, reason} ->
          Logger.warning("Could not list upstream models: #{inspect(reason)}")
          []
      end
    else
      []
    end
  end

  @doc """
  Resolves the `model` a client asked for.

    1. `meridian/<slug>`: that agent, if it exists and the policy allows it.
    2. A raw upstream model id, if `EXPOSE_UPSTREAM_MODELS` is enabled and the upstream lists it.
    3. Anything else (or no model at all): the policy's `default_agent`, falling back to the
       user's default agent. This lets clients with a hardcoded model name use Meridian.
  """
  @spec resolve_model(User.t(), Policy.t(), term()) :: {:ok, model()} | {:error, :model_not_found}
  def resolve_model(%User{} = user, %Policy{} = policy, model) do
    case Agent.slug_from_model_id(model) do
      {:ok, slug} ->
        user |> Agents.resolve_agent(policy, slug) |> model_result()

      :error ->
        if upstream_model?(model) do
          {:ok, {:upstream, model}}
        else
          user |> Agents.resolve_agent(policy, nil) |> model_result()
        end
    end
  end

  defp upstream_model?(model) do
    is_binary(model) and expose_upstream_models?() and
      Upstream.model_available?(model) == {:ok, true}
  end

  defp model_result({:ok, agent}), do: {:ok, {:agent, agent}}
  defp model_result({:error, :agent_not_found}), do: {:error, :model_not_found}

  @doc """
  Builds the upstream request body for a client request.

  For an agent, see `Meridian.Agents.apply_to_request/2`. Raw upstream models pass through
  untouched.
  """
  @spec build_request(model(), map()) :: map()
  def build_request({:upstream, _model}, body), do: body

  def build_request({:agent, %Agent{} = agent}, body),
    do: Agents.apply_to_request(agent, body)

  defp expose_upstream_models?, do: Upstream.config(:expose_models, false) == true
end
