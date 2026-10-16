defmodule Meridian.Upstream.ModelCache do
  @moduledoc """
  Caches the upstream's model list for a short time, so persona validation and `/v1/models`
  don't hit the upstream on every call.

  The process only owns the ETS table; reads and writes happen in the caller. Concurrent misses
  may fetch twice, which is harmless. The TTL is the `:model_cache_ttl` option (milliseconds)
  of `Meridian.Upstream`'s config.
  """
  use GenServer

  @table __MODULE__
  @default_ttl :timer.seconds(60)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns the cached model list, or `:miss` if there is none or it has expired."
  def get do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, :models) do
      [{:models, models, expires_at}] when expires_at > now -> {:ok, models}
      _ -> :miss
    end
  end

  @doc "Caches a model list."
  def put(models) do
    ttl = Meridian.Upstream.config(:model_cache_ttl, @default_ttl)
    :ets.insert(@table, {:models, models, System.monotonic_time(:millisecond) + ttl})
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
