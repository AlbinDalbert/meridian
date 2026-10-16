defmodule MeridianWeb.V1.ModelController do
  @moduledoc """
  `GET /v1/models`: the key's personas as models (`meridian/<slug>`), plus the raw upstream
  models when `EXPOSE_UPSTREAM_MODELS` is enabled.
  """
  use MeridianWeb, :controller

  alias Meridian.Personas.Persona
  alias Meridian.Proxy

  def index(conn, _params) do
    %{current_user: user, current_api_key: api_key} = conn.assigns

    data =
      for model <- Proxy.list_models(user, api_key.policy) do
        case model do
          {:persona, persona} ->
            %{
              id: Persona.model_id(persona),
              object: "model",
              created: DateTime.to_unix(persona.inserted_at),
              owned_by: "meridian"
            }

          {:upstream, id} ->
            %{id: id, object: "model", created: 0, owned_by: "upstream"}
        end
      end

    json(conn, %{object: "list", data: data})
  end
end
