defmodule Meridian.Agents do
  @moduledoc """
  Agents: named bundles of system prompt, upstream model, and default params that clients
  pick as a model (`meridian/<slug>`). Every agent belongs to a user, and each user has
  exactly one default agent.
  """
  import Ecto.Query

  alias Ecto.Changeset
  alias Meridian.Accounts.ApiKey.Policy
  alias Meridian.Accounts.User
  alias Meridian.Agents.Agent
  alias Meridian.Repo
  alias Meridian.Upstream

  def list_agents(%User{id: user_id}) do
    Repo.all(
      from p in Agent,
        where: p.user_id == ^user_id,
        order_by: [desc: p.is_default, asc: p.slug]
    )
  end

  @doc "Every user's agents, with their user, grouped by user."
  def list_all_agents do
    Repo.all(
      from p in Agent,
        join: u in assoc(p, :user),
        order_by: [asc: u.name, asc: u.id, desc: p.is_default, asc: p.slug],
        preload: [user: u]
    )
  end

  @doc """
  How many agents enable each extension, by extension id, whether it still exists or not.
  Extensions no agent enables aren't in the map.
  """
  def count_by_extension do
    Repo.all(
      from p in Agent, select: fragment("ARRAY(SELECT jsonb_object_keys(?))", p.extensions)
    )
    |> List.flatten()
    |> Enum.frequencies()
  end

  @doc """
  How many agents enable each skill, by skill id, whether it still exists or not. Skills no
  agent enables aren't in the map.
  """
  def count_by_skill do
    Repo.all(from p in Agent, select: p.skills)
    |> List.flatten()
    |> Enum.frequencies()
  end

  def get_agent!(id), do: Repo.get!(Agent, id)

  @doc "Gets agent `id` if it belongs to `user`; raises `Ecto.NoResultsError` otherwise."
  def get_agent!(%User{id: user_id}, id), do: Repo.get_by!(Agent, id: id, user_id: user_id)

  def get_agent_by_slug(%User{id: user_id}, slug) do
    Repo.get_by(Agent, user_id: user_id, slug: slug)
  end

  @doc """
  The upstream model of the newest user's default agent, or `nil` if there are no users. A
  sensible suggestion for the next user's.
  """
  def newest_default_model do
    Repo.one(
      from p in Agent, where: p.is_default, order_by: [desc: p.id], limit: 1, select: p.model
    )
  end

  def get_default_agent(%User{id: user_id}) do
    Repo.get_by(Agent, user_id: user_id, is_default: true)
  end

  @doc """
  Resolves the agent a key uses: the agent with `slug`, or with no slug the policy's
  `default_agent`, falling back to the user's default agent. Agents the policy doesn't
  allow are treated as not found.
  """
  @spec resolve_agent(User.t(), Policy.t(), String.t() | nil) ::
          {:ok, Agent.t()} | {:error, :agent_not_found}
  def resolve_agent(%User{} = user, %Policy{} = policy, slug) do
    agent =
      case {slug, policy.default_agent} do
        {nil, nil} -> get_default_agent(user)
        {nil, default} -> get_agent_by_slug(user, default)
        {slug, _default} -> get_agent_by_slug(user, slug)
      end

    if agent && Policy.allows?(policy, agent.slug),
      do: {:ok, agent},
      else: {:error, :agent_not_found}
  end

  @doc """
  Applies an agent to a chat completions request body: the agent's params are defaults the
  body can override, the model is replaced with the agent's upstream model, and the agent's
  system prompt goes before the body's (merged into its leading system message, if there is
  one, since some chat templates only accept a single system message).
  """
  @spec apply_to_request(Agent.t(), map()) :: map()
  def apply_to_request(%Agent{} = agent, body) do
    agent.params
    |> Map.merge(body)
    |> Map.put("model", agent.model)
    |> Map.update("messages", [], &put_system_prompt(&1, agent.system_prompt))
  end

  defp put_system_prompt(messages, prompt) when prompt in [nil, ""], do: messages

  defp put_system_prompt([%{"role" => role, "content" => content} = first | rest], prompt)
       when role in ["system", "developer"] do
    case content do
      text when is_binary(text) ->
        [%{first | "content" => prompt <> "\n\n" <> text} | rest]

      parts when is_list(parts) ->
        [%{first | "content" => [%{"type" => "text", "text" => prompt} | parts]} | rest]

      _ ->
        [%{"role" => "system", "content" => prompt}, first | rest]
    end
  end

  defp put_system_prompt(messages, prompt) when is_list(messages) do
    [%{"role" => "system", "content" => prompt} | messages]
  end

  # Not a valid message list; leave it for the upstream to reject.
  defp put_system_prompt(messages, _prompt), do: messages

  def change_agent(%Agent{} = agent, attrs \\ %{}), do: Agent.changeset(agent, attrs)

  @doc """
  Creates an agent for `user`.

  The upstream model is validated against the upstream's model list unless `force: true` is
  given (for upstreams that don't list every model, or that are temporarily down).
  """
  def create_agent(%User{} = user, attrs, opts \\ []) do
    %Agent{user_id: user.id}
    |> Agent.changeset(attrs)
    |> validate_model(opts)
    |> Repo.insert()
  end

  @doc "Updates an agent. Takes the same options as `create_agent/3`."
  def update_agent(%Agent{} = agent, attrs, opts \\ []) do
    agent
    |> Agent.changeset(attrs)
    |> validate_model(opts)
    |> Repo.update()
  end

  @doc "Deletes an agent. The default agent can't be deleted."
  def delete_agent(%Agent{is_default: true}), do: {:error, :default_agent}
  def delete_agent(%Agent{} = agent), do: Repo.delete(agent)

  @doc "Makes `agent` its user's default agent."
  def make_default(%Agent{is_default: true} = agent), do: {:ok, agent}

  def make_default(%Agent{} = agent) do
    Repo.transact(fn ->
      Repo.update_all(
        from(p in Agent, where: p.user_id == ^agent.user_id and p.is_default),
        set: [is_default: false]
      )

      agent |> Changeset.change(is_default: true) |> Repo.update()
    end)
  end

  @doc """
  Checks that a changed `:model` is offered by the upstream, unless `opts[:force]` is true.
  """
  def validate_model(%Changeset{} = changeset, opts) do
    model = Changeset.get_change(changeset, :model)

    if is_nil(model) or Keyword.get(opts, :force, false) or not changeset.valid? do
      changeset
    else
      case Upstream.model_available?(model) do
        {:ok, true} ->
          changeset

        {:ok, false} ->
          Changeset.add_error(changeset, :model, "is not offered by the upstream")

        {:error, :not_configured} ->
          Changeset.add_error(changeset, :model, "can't be validated: no upstream is configured")

        {:error, _reason} ->
          Changeset.add_error(changeset, :model, "can't be validated: upstream unreachable")
      end
    end
  end
end
