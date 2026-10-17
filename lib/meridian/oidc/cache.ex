defmodule Meridian.OIDC.Cache do
  @moduledoc """
  Caches the OIDC provider's discovery document and signing keys, so verifying a token doesn't
  hit the provider on every request.

  Like `Meridian.Upstream.ModelCache`, the process only owns the ETS table; reads and writes
  happen in the caller. The TTL is the `:cache_ttl` option (milliseconds) of `Meridian.OIDC`'s
  config.
  """
  use GenServer

  @table __MODULE__
  @default_ttl :timer.hours(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns `{:ok, value, age_ms}` for a cached, unexpired `key`, or `:miss`.
  """
  def get(key) do
    now = System.monotonic_time(:millisecond)
    ttl = ttl()

    case :ets.lookup(@table, key) do
      [{^key, value, stored_at}] when now - stored_at < ttl -> {:ok, value, now - stored_at}
      _ -> :miss
    end
  end

  @doc "Caches `value` under `key`."
  def put(key, value) do
    :ets.insert(@table, {key, value, System.monotonic_time(:millisecond)})
    :ok
  end

  defp ttl, do: Meridian.OIDC.config(:cache_ttl, @default_ttl)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
