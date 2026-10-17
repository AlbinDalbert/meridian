import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# In development, load `.env` (see example.env) into the environment, so `mix phx.server` picks
# it up without exporting anything first. Variables already set in the shell win, so one-off
# overrides like `PORT=4001 mix phx.server` still work. Releases and tests never read it.
# Format: `KEY=value` lines; blank lines, `#` comments, and an `export ` prefix are allowed,
# and a value may be wrapped in single or double quotes.
if config_env() == :dev and File.exists?(".env") do
  for line <- File.stream!(".env"),
      line = String.trim(line),
      line != "" and not String.starts_with?(line, "#"),
      [key, value] <- [
        line |> String.replace_prefix("export ", "") |> String.split("=", parts: 2)
      ],
      key = String.trim(key),
      is_nil(System.get_env(key)) do
    value =
      case String.trim(value) do
        "\"" <> rest -> String.trim_trailing(rest, "\"")
        "'" <> rest -> String.trim_trailing(rest, "'")
        value -> value
      end

    System.put_env(key, value)
  end
end

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/meridian start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :meridian, MeridianWeb.Endpoint, server: true
end

config :meridian, MeridianWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() != :test do
  config :meridian, Meridian.Upstream,
    base_url: System.get_env("LLM_BASE_URL"),
    api_key: System.get_env("LLM_API_KEY"),
    expose_models: System.get_env("EXPOSE_UPSTREAM_MODELS") in ~w(true 1)

  # Unset (or empty) disables /admin entirely.
  admin_token =
    case System.get_env("ADMIN_TOKEN") do
      token when token in [nil, ""] -> nil
      token -> token
    end

  if (config_env() == :prod and admin_token) && byte_size(admin_token) < 32 do
    raise """
    environment variable ADMIN_TOKEN is too short (minimum 32 characters).
    You can generate one by calling: openssl rand -base64 48
    """
  end

  config :meridian, :admin_token, admin_token

  # OIDC (e.g. WorkOS AuthKit): sign-in for /admin and for clients. See README "Signing in".
  env_list = fn name ->
    System.get_env(name, "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  env = fn name ->
    case System.get_env(name) do
      value when value in [nil, ""] -> nil
      value -> String.trim(value)
    end
  end

  oidc_issuer = env.("OIDC_ISSUER")
  oidc_audiences = env_list.("OIDC_AUDIENCES")
  admin_oidc_client_id = env.("ADMIN_OIDC_CLIENT_ID")
  admin_emails = "ADMIN_EMAILS" |> env_list.() |> Enum.map(&String.downcase/1)

  cond do
    is_nil(oidc_issuer) and (oidc_audiences != [] or admin_oidc_client_id) ->
      raise "OIDC_AUDIENCES and ADMIN_OIDC_CLIENT_ID need OIDC_ISSUER to be set."

    admin_oidc_client_id && admin_emails == [] ->
      raise "ADMIN_OIDC_CLIENT_ID is set but ADMIN_EMAILS is empty, so nobody could sign in."

    true ->
      :ok
  end

  config :meridian, Meridian.OIDC, issuer: oidc_issuer, audiences: oidc_audiences

  config :meridian,
         :admin_oidc,
         admin_oidc_client_id &&
           [
             client_id: admin_oidc_client_id,
             client_secret: env.("ADMIN_OIDC_CLIENT_SECRET"),
             emails: admin_emails
           ]

  # Browser apps allowed to call /v1 and /api: comma-separated origins, or "*".
  cors_allowed_origins =
    case System.get_env("CORS_ALLOWED_ORIGINS", "") |> String.trim() do
      "*" ->
        :all

      origins ->
        origins
        |> String.split(",", trim: true)
        |> Enum.map(&(&1 |> String.trim() |> String.trim_trailing("/")))
        |> Enum.reject(&(&1 == ""))
    end

  config :meridian, :cors_allowed_origins, cors_allowed_origins
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :meridian, Meridian.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :meridian, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :meridian, MeridianWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :meridian, MeridianWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :meridian, MeridianWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
