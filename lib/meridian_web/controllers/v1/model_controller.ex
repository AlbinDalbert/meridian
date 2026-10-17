defmodule MeridianWeb.V1.ModelController do
  @moduledoc """
  `GET /v1/models`: the key's agents as models (`meridian/<slug>`), plus the raw upstream
  models when `EXPOSE_UPSTREAM_MODELS` is enabled.
  """
  use MeridianWeb, :controller

  alias Meridian.Agents.Agent
  alias Meridian.Proxy

  def index(conn, _params) do
    %{current_user: user, current_policy: policy} = conn.assigns

    data =
      for model <- Proxy.list_models(user, policy) do
        case model do
          {:agent, agent} ->
            %{
              id: Agent.model_id(agent),
              object: "model",
              created: DateTime.to_unix(agent.inserted_at),
              owned_by: "meridian"
            }

          {:upstream, id} ->
            %{id: id, object: "model", created: 0, owned_by: "upstream"}
        end
      end

    json(conn, %{object: "list", data: data})
  end
end
