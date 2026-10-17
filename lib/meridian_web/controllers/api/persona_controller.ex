defmodule MeridianWeb.Api.PersonaController do
  @moduledoc """
  `GET /api/personas`: the personas the caller may use. `id` is what threads take as `persona`;
  `default` marks the one a thread gets without one.
  """
  use MeridianWeb, :controller

  alias Meridian.Accounts.ApiKey.Policy
  alias Meridian.Personas
  alias Meridian.Personas.Persona

  def index(conn, _params) do
    %{current_user: user, current_policy: policy} = conn.assigns
    default = Personas.resolve_persona(user, policy, nil)

    data =
      for persona <- Personas.list_personas(user), Policy.allows?(policy, persona.slug) do
        %{
          id: Persona.model_id(persona),
          name: persona.name,
          model: persona.model,
          default: match?({:ok, %{id: id}} when id == persona.id, default)
        }
      end

    json(conn, %{data: data})
  end
end
