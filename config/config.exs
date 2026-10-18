# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :meridian,
  ecto_repos: [Meridian.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true]

# Extensions are Lua scripts kept in the database (see Meridian.Extensions). Hook handlers that
# take longer than `hook_timeout` (milliseconds) are skipped; background jobs get `job_timeout`.
# Hooks get as long as tools, so they can call the model (e.g. a guardrail checking a reply).
config :meridian, Meridian.Extensions,
  hook_timeout: :timer.seconds(30),
  job_timeout: :timer.minutes(1)

config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :meridian, Oban,
  engine: Oban.Engines.Basic,
  repo: Meridian.Repo,
  queues: [default: 10, runs: 50, extensions: 10],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Jobs of a node that died are left "executing"; this discards them (runs aren't retried).
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron, crontab: [{"* * * * *", Meridian.Runs.Janitor}]}
  ]

# Run execution tuning (milliseconds). See Meridian.Runs.RunServer.
config :meridian, Meridian.Runs,
  delta_flush_interval: 100,
  heartbeat_interval: :timer.seconds(10),
  stale_after: :timer.seconds(60),
  idle_timeout: :timer.minutes(5)

# Configure the endpoint
config :meridian, MeridianWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: MeridianWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Meridian.PubSub,
  live_view: [signing_salt: "q3Vx7nKcR2bLwE9d"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Run event stream tokens travel in the query string (EventSource can't send headers).
config :phoenix, :filter_parameters, ["password", "token"]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
