defmodule Meridian.Upstream do
  @moduledoc """
  Client for the OpenAI-compatible inference endpoint behind Meridian.

  Configured from `LLM_BASE_URL` (including the `/v1` suffix) and the optional `LLM_API_KEY`.
  The upstream is treated as a dumb, stateless model endpoint.
  """

  alias Meridian.Upstream.ModelCache

  @doc """
  Lists the upstream's model ids. Results are cached briefly (see `Meridian.Upstream.ModelCache`).
  """
  @spec list_models() :: {:ok, [String.t()]} | {:error, term()}
  def list_models do
    case ModelCache.get() do
      {:ok, models} ->
        {:ok, models}

      :miss ->
        with {:ok, models} <- fetch_models() do
          ModelCache.put(models)
          {:ok, models}
        end
    end
  end

  @doc """
  Checks whether the upstream lists `model`. Returns `{:error, reason}` if the upstream can't be
  asked.
  """
  @spec model_available?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def model_available?(model) do
    with {:ok, models} <- list_models(), do: {:ok, model in models}
  end

  @doc """
  Sends a chat completions request. The response body is not read: it is streamed into the
  calling process (`Req.Response.Async`), so it can be relayed as it arrives and cancelled with
  `Req.cancel_async_response/1`. This works the same for streaming and non-streaming requests.
  """
  @spec chat_completions(map()) :: {:ok, Req.Response.t()} | {:error, term()}
  def chat_completions(body) when is_map(body) do
    with {:ok, req} <- new() do
      Req.post(req,
        url: "/chat/completions",
        json: body,
        into: :self,
        # Relay the bytes exactly as the upstream sends them.
        compressed: false,
        decode_body: false,
        retry: false,
        receive_timeout: config(:receive_timeout, :timer.minutes(5))
      )
    end
  end

  @doc """
  Sends a non-streaming chat completions request and returns the decoded response. For
  background work that just wants the answer; replies to users stream (`Meridian.Upstream.Stream`).
  """
  @spec complete(map()) :: {:ok, map()} | {:error, term()}
  def complete(body) when is_map(body) do
    with {:ok, req} <- new() do
      case Req.post(req,
             url: "/chat/completions",
             json: Map.put(body, "stream", false),
             retry: false,
             receive_timeout: config(:receive_timeout, :timer.minutes(5))
           ) do
        {:ok, %Req.Response{status: 200, body: %{} = response}} -> {:ok, response}
        {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_response, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_models do
    with {:ok, req} <- new(),
         {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_list(data) <-
           Req.get(req, url: "/models", retry: false, receive_timeout: :timer.seconds(10)) do
      {:ok, for(%{"id" => id} when is_binary(id) <- data, do: id)}
    else
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_response, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp new do
    case config(:base_url) do
      base_url when base_url in [nil, ""] ->
        {:error, :not_configured}

      base_url ->
        req =
          [base_url: base_url]
          |> Keyword.merge(config(:req_options, []))
          |> Req.new()
          |> maybe_auth(config(:api_key))

        {:ok, req}
    end
  end

  defp maybe_auth(req, key) when key in [nil, ""], do: req
  defp maybe_auth(req, key), do: Req.merge(req, auth: {:bearer, key})

  @doc false
  def config(key, default \\ nil) do
    :meridian |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
