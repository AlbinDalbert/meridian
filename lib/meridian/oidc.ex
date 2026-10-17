defmodule Meridian.OIDC do
  @moduledoc """
  Client for the deployment's OpenID Connect provider (`OIDC_ISSUER`), e.g. WorkOS AuthKit,
  Keycloak, Authentik, Google, or Entra.

  Meridian uses the provider in two ways:

    * **Verifying access tokens** that clients send instead of an API key
      (`verify_token/3`). Meridian acts as a resource server: clients run the login themselves
      and Meridian only checks the token's signature and claims.
    * **Signing people in** with the authorization code flow and PKCE (`authorize_url/1`,
      `complete_sign_in/1`): operators into `/admin` (see `MeridianWeb.AdminAuth`), and users
      of browser apps into `/api` (see `MeridianWeb.UserAuth`).

  Endpoints and signing keys come from the provider's discovery document
  (`<issuer>/.well-known/openid-configuration`) and are cached (see `Meridian.OIDC.Cache`).
  """
  require Logger

  alias Meridian.OIDC.{Cache, JWT}

  # Signing keys are refetched for an unknown `kid` at most this often, so tokens with made-up
  # key ids can't make us hammer the provider.
  @min_jwks_refresh_ms :timer.seconds(60)

  @doc "The configured issuer, or `nil` if OIDC is off."
  def issuer, do: config(:issuer)

  @doc "Audiences accepted on client access tokens (`OIDC_AUDIENCES`)."
  def audiences, do: config(:audiences, [])

  @doc "Whether clients may authenticate with an access token from the provider."
  def client_tokens_enabled?, do: issuer() != nil and audiences() != []

  @doc """
  Verifies a JWT issued by the provider for one of `audiences`. See `Meridian.OIDC.JWT.verify/3`
  for `opts` (`:nonce`).
  """
  @spec verify_token(String.t(), [String.t()], keyword()) ::
          {:ok, JWT.claims()} | {:error, term()}
  def verify_token(token, audiences, opts \\ []) do
    with {:ok, discovery} <- discovery(),
         {:ok, keys} <- jwks(discovery) do
      opts = Keyword.merge(opts, issuer: discovery["issuer"], audiences: audiences)

      case JWT.verify(token, keys, opts) do
        {:error, :unknown_key} ->
          with {:ok, keys} <- jwks(discovery, refresh: true), do: JWT.verify(token, keys, opts)

        result ->
          result
      end
    end
  end

  @doc """
  The URL to send a browser to for logging in. `params` must include `:client_id`,
  `:redirect_uri`, `:state`, `:nonce`, and `:code_challenge` (S256).
  """
  def authorize_url(params) do
    with {:ok, %{"authorization_endpoint" => endpoint}} <- discovery() do
      query =
        URI.encode_query(%{
          response_type: "code",
          scope: "openid email profile",
          client_id: Keyword.fetch!(params, :client_id),
          redirect_uri: Keyword.fetch!(params, :redirect_uri),
          state: Keyword.fetch!(params, :state),
          nonce: Keyword.fetch!(params, :nonce),
          code_challenge: Keyword.fetch!(params, :code_challenge),
          code_challenge_method: "S256"
        })

      {:ok, endpoint <> if(String.contains?(endpoint, "?"), do: "&", else: "?") <> query}
    end
  end

  @doc """
  Exchanges an authorization code for tokens at the token endpoint. `params` must include
  `:client_id`, `:redirect_uri`, `:code`, and `:code_verifier`; `:client_secret` is sent if
  set (confidential clients). Returns the token response (`"id_token"`, `"access_token"`, ...).
  """
  def exchange_code(params) do
    form =
      %{
        grant_type: "authorization_code",
        code: Keyword.fetch!(params, :code),
        redirect_uri: Keyword.fetch!(params, :redirect_uri),
        client_id: Keyword.fetch!(params, :client_id),
        code_verifier: Keyword.fetch!(params, :code_verifier)
      }
      |> then(fn form ->
        if secret = params[:client_secret], do: Map.put(form, :client_secret, secret), else: form
      end)

    with {:ok, %{"token_endpoint" => endpoint}} <- discovery() do
      case Req.post(req(), url: endpoint, form: form) do
        {:ok, %Req.Response{status: 200, body: %{"id_token" => _} = body}} ->
          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning("OIDC token exchange failed: #{status} #{inspect(body)}")
          {:error, :token_exchange_failed}

        {:error, reason} ->
          Logger.warning("OIDC token exchange failed: #{Exception.message(reason)}")
          {:error, :provider_unavailable}
      end
    end
  end

  @doc """
  Finishes an authorization code sign-in: exchanges the code (`params` as for
  `exchange_code/1`, plus `:nonce`), then verifies the ID token for `:client_id` and `:nonce`.
  Returns the ID token's claims, with the userinfo endpoint's merged in if the ID token carries
  no email.
  """
  @spec complete_sign_in(keyword()) :: {:ok, JWT.claims()} | {:error, term()}
  def complete_sign_in(params) do
    client_id = Keyword.fetch!(params, :client_id)
    nonce = Keyword.fetch!(params, :nonce)

    with {:ok, %{"id_token" => id_token} = tokens} <- exchange_code(params),
         {:ok, claims} <- verify_token(id_token, [client_id], nonce: nonce) do
      with_email(claims, tokens)
    end
  end

  defp with_email(%{"email" => email} = claims, _tokens) when is_binary(email), do: {:ok, claims}

  defp with_email(%{"sub" => subject} = claims, %{"access_token" => access_token}) do
    case userinfo(access_token) do
      {:ok, %{"sub" => ^subject} = info} -> {:ok, Map.merge(claims, info)}
      _ -> {:error, :no_email}
    end
  end

  defp with_email(_claims, _tokens), do: {:error, :no_email}

  @doc "Fetches the provider's claims about the user an access token belongs to."
  def userinfo(access_token) do
    with {:ok, %{"userinfo_endpoint" => endpoint}} <- discovery() do
      case Req.get(req(), url: endpoint, auth: {:bearer, access_token}) do
        {:ok, %Req.Response{status: 200, body: %{"sub" => _} = body}} -> {:ok, body}
        {:ok, %Req.Response{}} -> {:error, :userinfo_failed}
        {:error, _reason} -> {:error, :provider_unavailable}
      end
    else
      {:ok, %{}} -> {:error, :no_userinfo_endpoint}
      error -> error
    end
  end

  @doc "A random URL-safe string, for `state`, `nonce`, and PKCE code verifiers."
  def random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc "The S256 PKCE code challenge for a code verifier."
  def code_challenge(verifier),
    do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  defp discovery do
    case issuer() do
      nil ->
        {:error, :not_configured}

      issuer ->
        cached({:discovery, issuer}, fn ->
          url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

          case fetch_json(url) do
            # The document must be about the issuer we were configured with.
            {:ok, %{"issuer" => ^issuer, "jwks_uri" => _} = doc} ->
              {:ok, doc}

            {:ok, %{}} ->
              Logger.warning("OIDC discovery at #{url} doesn't match OIDC_ISSUER #{issuer}")
              {:error, :invalid_discovery}

            error ->
              error
          end
        end)
    end
  end

  defp jwks(%{"jwks_uri" => uri}, opts \\ []) do
    key = {:jwks, uri}

    fetch = fn ->
      case fetch_json(uri) do
        {:ok, %{"keys" => keys}} when is_list(keys) -> {:ok, keys}
        {:ok, _} -> {:error, :invalid_jwks}
        error -> error
      end
    end

    refresh? = Keyword.get(opts, :refresh, false)

    case Cache.get(key) do
      {:ok, keys, age} when not refresh? or age < @min_jwks_refresh_ms -> {:ok, keys}
      _ -> fetch_and_cache(key, fetch)
    end
  end

  defp cached(key, fetch) do
    case Cache.get(key) do
      {:ok, value, _age} -> {:ok, value}
      :miss -> fetch_and_cache(key, fetch)
    end
  end

  defp fetch_and_cache(key, fetch) do
    with {:ok, value} <- fetch.() do
      Cache.put(key, value)
      {:ok, value}
    end
  end

  defp fetch_json(url) do
    case Req.get(req(), url: url) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("OIDC request to #{url} failed with status #{status}")
        {:error, :provider_unavailable}

      {:error, reason} ->
        Logger.warning("OIDC request to #{url} failed: #{Exception.message(reason)}")
        {:error, :provider_unavailable}
    end
  end

  defp req do
    [retry: false, receive_timeout: :timer.seconds(10)]
    |> Keyword.merge(config(:req_options, []))
    |> Req.new()
  end

  @doc false
  def config(key, default \\ nil) do
    :meridian |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
