defmodule Meridian.Repo do
  use Ecto.Repo,
    otp_app: :meridian,
    adapter: Ecto.Adapters.Postgres
end
