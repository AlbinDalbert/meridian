defmodule Meridian.OIDC.JWTTest do
  use ExUnit.Case, async: true

  alias Meridian.OIDC.JWT
  alias Meridian.OIDCStub

  @opts [issuer: "https://auth.test", audiences: ["client_app"]]

  defp keys, do: [OIDCStub.public_jwk()]

  test "accepts a valid token and returns its claims" do
    token = OIDCStub.sign(%{"sub" => "user_1"})
    assert {:ok, %{"sub" => "user_1"}} = JWT.verify(token, keys(), @opts)
  end

  test "accepts an audience list containing an accepted audience" do
    token = OIDCStub.sign(%{"sub" => "user_1", "aud" => ["other", "client_app"]})
    assert {:ok, _claims} = JWT.verify(token, keys(), @opts)
  end

  test "rejects a tampered payload" do
    [header, _payload, signature] = String.split(OIDCStub.sign(%{"sub" => "user_1"}), ".")
    payload = Base.url_encode64(Jason.encode!(%{"sub" => "admin"}), padding: false)

    assert {:error, :invalid_signature} =
             JWT.verify(Enum.join([header, payload, signature], "."), keys(), @opts)
  end

  test "rejects algorithms other than RS256" do
    for alg <- ["none", "HS256", "RS512"] do
      token = OIDCStub.sign(%{"sub" => "user_1"}, alg: alg)
      assert {:error, :unsupported_algorithm} = JWT.verify(token, keys(), @opts)
    end
  end

  test "rejects the wrong issuer, audience, or nonce" do
    assert {:error, :invalid_issuer} =
             JWT.verify(
               OIDCStub.sign(%{"sub" => "u", "iss" => "https://evil.test"}),
               keys(),
               @opts
             )

    assert {:error, :invalid_audience} =
             JWT.verify(OIDCStub.sign(%{"sub" => "u", "aud" => "other"}), keys(), @opts)

    token = OIDCStub.sign(%{"sub" => "u", "nonce" => "abc"})
    assert {:ok, _} = JWT.verify(token, keys(), Keyword.put(@opts, :nonce, "abc"))
    assert {:error, :invalid_nonce} = JWT.verify(token, keys(), Keyword.put(@opts, :nonce, "xyz"))

    assert {:error, :invalid_nonce} =
             JWT.verify(OIDCStub.sign(%{"sub" => "u"}), keys(), Keyword.put(@opts, :nonce, "abc"))
  end

  test "rejects expired and not-yet-valid tokens, allowing a minute of clock skew" do
    now = System.system_time(:second)

    assert {:error, :expired} =
             JWT.verify(OIDCStub.sign(%{"sub" => "u", "exp" => now - 120}), keys(), @opts)

    assert {:ok, _} = JWT.verify(OIDCStub.sign(%{"sub" => "u", "exp" => now - 10}), keys(), @opts)

    assert {:error, :not_yet_valid} =
             JWT.verify(OIDCStub.sign(%{"sub" => "u", "nbf" => now + 300}), keys(), @opts)
  end

  test "requires a subject" do
    assert {:error, :missing_subject} = JWT.verify(OIDCStub.sign(%{}), keys(), @opts)
  end

  test "reports an unknown key id, so the caller can refetch the keys" do
    token = OIDCStub.sign(%{"sub" => "u"}, kid: "rotated")
    assert {:error, :unknown_key} = JWT.verify(token, keys(), @opts)
  end

  test "rejects garbage" do
    assert {:error, :malformed} = JWT.verify("not-a-jwt", keys(), @opts)
    assert {:error, :malformed} = JWT.verify("a.b.c", keys(), @opts)
    refute JWT.jwt?("mrd_abc")
  end
end
