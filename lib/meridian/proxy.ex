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
        user |> Personas.get_persona_by_slug(slug) |> allowed(policy)

      :error ->
        if upstream_model?(model) do
          {:ok, {:upstream, model}}
        else
          user |> default_persona(policy) |> allowed(policy)
        end
    end
  end

  defp upstream_model?(model) do
    is_binary(model) and expose_upstream_models?() and
      Upstream.model_available?(model) == {:ok, true}
  end

  defp default_persona(user, %Policy{default_persona: nil}),
    do: Personas.get_default_persona(user)

  defp default_persona(user, %Policy{default_persona: slug}),
    do: Personas.get_persona_by_slug(user, slug)

  defp allowed(%Persona{} = persona, policy) do
    if Policy.allows?(policy, persona.slug),
      do: {:ok, {:persona, persona}},
      else: {:error, :model_not_found}
  end

  defp allowed(nil, _policy), do: {:error, :model_not_found}

  @doc """
  Builds the upstream request body for a client request.

  For a persona: the persona's params are defaults the client can override, the model is
  replaced with the persona's upstream model, and the persona's system prompt goes before the
  client's (merged into the client's leading system message, if there is one, since some chat
  templates only accept a single system message). Raw upstream models pass through untouched.
  """
  @spec build_request(model(), map()) :: map()
  def build_request({:upstream, _model}, body), do: body

  def build_request({:persona, %Persona{} = persona}, body) do
    persona.params
    |> Map.merge(body)
    |> Map.put("model", persona.model)
    |> Map.update("messages", [], &put_system_prompt(&1, persona.system_prompt))
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

  defp expose_upstream_models?, do: Upstream.config(:expose_models, false) == true
end
