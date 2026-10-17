import Config

# Force using SSL in production. This also sets the "strict-security-transport" header,
# known as HSTS. Note `:force_ssl` is required to be set at compile-time.
config :meridian, MeridianWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      # Kubernetes probes call the pod directly over plain HTTP. Redirected, they would
      # count as passing (kubelet treats a redirect to another host as success) even with the
      # database down.
      paths: ["/healthz", "/readyz"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
