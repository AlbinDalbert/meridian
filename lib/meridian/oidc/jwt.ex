defmodule Meridian.OIDC.JWT do
  @moduledoc """
  Verifies signed JWTs (ID tokens and access tokens) against a provider's JSON Web Key Set.

  Only RS256 is accepted. It is what OIDC requires providers to support and what WorkOS AuthKit,
  Keycloak, Google, and Entra sign with by default. Anything else (including `none` and the HMAC
  algorithms) is rejected, so a token can't pick a weaker check for itself.
  """

  # Allowed clock skew between us and the provider, in seconds.
  @leeway 60

  @type claims :: %{optional(String.t()) => term()}

  @doc """
  Verifies `token`'s signature with one of `keys` (JWKS `keys` entries), then its claims.

  Options:

    * `:issuer` (required) - the exact `iss` the token must have.
    * `:audiences` (required) - the token's `aud` must contain at least one of them.
    * `:nonce` - if given, the token's `nonce` must equal it (ID tokens).

  Returns `{:error, :unknown_key}` if no key matches the token's `kid`, so the caller can refetch
  the key set once (providers rotate keys).
  """
  @spec verify(String.t(), [map()], keyword()) :: {:ok, claims()} | {:error, atom()}
  def verify(token, keys, opts) when is_binary(token) do
    with {:ok, header_part, payload_part, signature} <- split(token),
         {:ok, %{"alg" => "RS256"} = header} <- decode_json(header_part),
         {:ok, key} <- find_key(keys, header["kid"]),
         :ok <- verify_signature(header_part <> "." <> payload_part, signature, key),
         {:ok, %{} = claims} <- decode_json(payload_part),
         :ok <- validate_claims(claims, opts) do
      {:ok, claims}
    else
      {:ok, %{}} -> {:error, :unsupported_algorithm}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed}
    end
  end

  def verify(_token, _keys, _opts), do: {:error, :malformed}

  @doc "Whether a string has the shape of a JWT (three base64url parts)."
  def jwt?(token) when is_binary(token), do: match?({:ok, _, _, _}, split(token))
  def jwt?(_token), do: false

  defp split(token) do
    with [header, payload, signature] <- String.split(token, "."),
         true <- header != "" and payload != "",
         {:ok, signature} <- Base.url_decode64(signature, padding: false) do
      {:ok, header, payload, signature}
    else
      _ -> {:error, :malformed}
    end
  end

  defp decode_json(part) do
    with {:ok, json} <- Base.url_decode64(part, padding: false),
         {:ok, decoded} <- Jason.decode(json) do
      {:ok, decoded}
    else
      _ -> {:error, :malformed}
    end
  end

  # With a `kid`, the key must carry the same one. Without one (rare), any RSA signing key may
  # match; verify_signature/3 then decides.
  defp find_key(keys, kid) do
    keys
    |> Enum.filter(&(&1["kty"] == "RSA" and &1["use"] in [nil, "sig"]))
    |> Enum.filter(&(kid == nil or &1["kid"] == kid))
    |> case do
      [key | _] -> {:ok, key}
      [] -> {:error, :unknown_key}
    end
  end

  defp verify_signature(signing_input, signature, %{"n" => n, "e" => e}) do
    with {:ok, n} <- Base.url_decode64(n, padding: false),
         {:ok, e} <- Base.url_decode64(e, padding: false),
         true <- :crypto.verify(:rsa, :sha256, signing_input, signature, [e, n]) do
      :ok
    else
      _ -> {:error, :invalid_signature}
    end
  end

  defp verify_signature(_signing_input, _signature, _key), do: {:error, :invalid_signature}

  defp validate_claims(claims, opts) do
    now = System.system_time(:second)
    issuer = Keyword.fetch!(opts, :issuer)
    audiences = Keyword.fetch!(opts, :audiences)

    cond do
      claims["iss"] != issuer -> {:error, :invalid_issuer}
      not audience?(claims["aud"], audiences) -> {:error, :invalid_audience}
      not is_integer(claims["exp"]) or claims["exp"] + @leeway <= now -> {:error, :expired}
      is_integer(claims["nbf"]) and claims["nbf"] - @leeway > now -> {:error, :not_yet_valid}
      not is_binary(claims["sub"]) or claims["sub"] == "" -> {:error, :missing_subject}
      not nonce?(claims, opts[:nonce]) -> {:error, :invalid_nonce}
      true -> :ok
    end
  end

  defp audience?(aud, audiences) when is_binary(aud), do: aud in audiences
  defp audience?(aud, audiences) when is_list(aud), do: Enum.any?(aud, &(&1 in audiences))
  defp audience?(_aud, _audiences), do: false

  defp nonce?(_claims, nil), do: true
  defp nonce?(%{"nonce" => nonce}, expected) when is_binary(nonce), do: nonce == expected
  defp nonce?(_claims, _expected), do: false
end
