defmodule Meridian.OIDCStub do
  @moduledoc """
  A fake OIDC provider for tests, at the issuer configured in `config/test.exs`
  (`https://auth.test`). Tokens are signed with a test RSA key generated once per run (`setup_key/0`).

      Meridian.OIDCStub.stub(userinfo: %{"sub" => "user_1", "email" => "ada@example.com"})
      token = Meridian.OIDCStub.sign(%{"sub" => "user_1"})

  Each userinfo and token request is sent to the test process as `{:oidc_request, path, params}`.
  """

  @issuer "https://auth.test"
  @kid "test-key"

  def issuer, do: @issuer

  @doc """
  Stubs the provider. Options:

    * `:userinfo` - the userinfo response body (default: 401).
    * `:token` - a function from the token request's form params to the response body
      (default: 400).
  """
  def stub(opts \\ []) do
    test = self()

    Req.Test.stub(Meridian.OIDC, fn conn ->
      case conn.request_path do
        "/.well-known/openid-configuration" ->
          Req.Test.json(conn, discovery())

        "/oauth2/jwks" ->
          Req.Test.json(conn, %{"keys" => [public_jwk()]})

        "/oauth2/userinfo" ->
          send(
            test,
            {:oidc_request, "/oauth2/userinfo", Plug.Conn.get_req_header(conn, "authorization")}
          )

          case opts[:userinfo] do
            nil ->
              conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "invalid_token"})

            info ->
              Req.Test.json(conn, info)
          end

        "/oauth2/token" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          params = URI.decode_query(body)
          send(test, {:oidc_request, "/oauth2/token", params})

          case opts[:token] do
            nil ->
              conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})

            fun ->
              Req.Test.json(conn, fun.(params))
          end
      end
    end)
  end

  def discovery do
    %{
      "issuer" => @issuer,
      "authorization_endpoint" => @issuer <> "/oauth2/authorize",
      "token_endpoint" => @issuer <> "/oauth2/token",
      "userinfo_endpoint" => @issuer <> "/oauth2/userinfo",
      "jwks_uri" => @issuer <> "/oauth2/jwks"
    }
  end

  @doc """
  Signs `claims` as an RS256 JWT. `iss`, `aud` (`"client_app"`), `iat`, and `exp` (in an hour)
  are filled in unless given. Options: `:kid`, `:alg` (header only; the signature is RS256).
  """
  def sign(claims, opts \\ []) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{"iss" => @issuer, "aud" => "client_app", "iat" => now, "exp" => now + 3600},
        claims
      )

    header = %{
      "alg" => Keyword.get(opts, :alg, "RS256"),
      "typ" => "JWT",
      "kid" => Keyword.get(opts, :kid, @kid)
    }

    signing_input = encode(header) <> "." <> encode(claims)
    signature = :public_key.sign(signing_input, :sha256, private_key())
    signing_input <> "." <> Base.url_encode64(signature, padding: false)
  end

  def public_jwk do
    {:RSAPrivateKey, _version, modulus, exponent, _d, _p, _q, _dp, _dq, _qi, _other} =
      private_key()

    %{
      "kty" => "RSA",
      "use" => "sig",
      "alg" => "RS256",
      "kid" => @kid,
      "n" => Base.url_encode64(:binary.encode_unsigned(modulus), padding: false),
      "e" => Base.url_encode64(:binary.encode_unsigned(exponent), padding: false)
    }
  end

  @doc "Generates the signing key. Called once from test_helper.exs, before tests run concurrently."
  def setup_key do
    :persistent_term.put({__MODULE__, :key}, :public_key.generate_key({:rsa, 2048, 65_537}))
  end

  defp private_key, do: :persistent_term.get({__MODULE__, :key})

  defp encode(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)
end
