import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :meridian, Meridian.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "meridian_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :meridian, MeridianWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Jw7mU0x67CLzVkXnQnQoBHP9L2/jukubQO1+aCziqJDuHMiNusqvan0GyB3vl/Pn",
  server: false

# The upstream is stubbed with Req.Test; the model list is never cached between tests.
config :meridian, Meridian.Upstream,
  base_url: "http://upstream.test/v1",
  req_options: [plug: {Req.Test, Meridian.Upstream}],
  model_cache_ttl: 0

config :meridian, :cors_allowed_origins, ["https://app.example"]

config :meridian, :admin_token, "test-admin-token-0123456789abcdefghijklmnopqrstuvwxyz"

# The OIDC provider is stubbed with Req.Test (see Meridian.OIDCStub); nothing is cached between
# tests. Admin sign-in with it is off unless a test turns it on.
config :meridian, Meridian.OIDC,
  issuer: "https://auth.test",
  audiences: ["client_app"],
  req_options: [plug: {Req.Test, Meridian.OIDC}],
  cache_ttl: 0

config :meridian, :admin_oidc, nil

# One message.delta event per upstream chunk, so tests are deterministic.
config :meridian, Meridian.Runs, delta_flush_interval: 0

# Meridian.TestExtension (test/support) reports its hook calls to the test that enabled it.
config :meridian, :extensions, [Meridian.Ext.Datetime, Meridian.Ext.Title, Meridian.TestExtension]

config :meridian, Meridian.Extensions, hook_timeout: 200

# Jobs are executed explicitly in tests (see Oban.Testing)
config :meridian, Oban, testing: :manual

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
