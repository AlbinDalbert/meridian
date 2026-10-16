defmodule Meridian.Proxy do
  @moduledoc """
  The stateless, OpenAI-compatible surface (`/v1/*`): a persona-aware proxy.

  The client owns the conversation and the tool loop. Meridian resolves the requested model to
  a persona, applies the persona's system prompt, upstream model, and default params, and
  forwards everything else to the upstream unchanged.
  """
  require Logger

  alias Meridian.Accounts.ApiKey.Policy
  alias Meridian.Accounts.User
  alias Meridian.Personas
  alias Meridian.Personas.Persona
  alias Meridian.Upstream

  @type model :: {:persona, Persona.t()} | {:upstream, String.t()}

  @doc """
  The models a key can use: the user's personas the policy allows, plus the raw upstream models
  if `EXPOSE_UPSTREAM_MODELS` is enabled.
  """
  @spec list_models(User.t(), Policy.t()) :: [model()]
  def list_models(%User{} = user, %Policy{} = policy) do
    personas =
      for persona <- Personas.list_personas(user), Policy.allows?(policy, persona.slug) do
        {:persona, persona}
      end

    personas ++ upstream_models()
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

    1. `meridian/<slug>`: that persona, if it exists and the policy allows it.
    2. A raw upstream model id, if `EXPOSE_UPSTREAM_MODELS` is enabled and the upstream lists it.
    3. Anything else (or no model at all): the policy's `default_persona`, falling back to the
       user's default persona. This lets clients with a hardcoded model name use Meridian.
  """
  @spec resolve_model(User.t(), Policy.t(), term()) :: {:ok, model()} | {:error, :model_not_found}
  def resolve_model(%User{} = user, %Policy{} = policy, model) do
    case Persona.slug_from_model_id(model) do
      {:ok, slug} ->
        user |> Personas.resolve_persona(policy, slug) |> model_result()

      :error ->
        if upstream_model?(model) do
          {:ok, {:upstream, model}}
        else
          user |> Personas.resolve_persona(policy, nil) |> model_result()
        end
    end
  end

  defp upstream_model?(model) do
    is_binary(model) and expose_upstream_models?() and
      Upstream.model_available?(model) == {:ok, true}
  end

  defp model_result({:ok, persona}), do: {:ok, {:persona, persona}}
  defp model_result({:error, :persona_not_found}), do: {:error, :model_not_found}

  @doc """
  Builds the upstream request body for a client request.

  For a persona, see `Meridian.Personas.apply_to_request/2`. Raw upstream models pass through
  untouched.
  """
  @spec build_request(model(), map()) :: map()
  def build_request({:upstream, _model}, body), do: body

  def build_request({:persona, %Persona{} = persona}, body),
    do: Personas.apply_to_request(persona, body)

  defp expose_upstream_models?, do: Upstream.config(:expose_models, false) == true
end
