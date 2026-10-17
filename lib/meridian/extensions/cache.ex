defmodule Meridian.Extensions.Cache do
  @moduledoc """
  Loaded scripts, so a script is loaded once per version rather than for every hook call, and
  each extension's latest error. An ETS table owned by this process; anyone reads and writes it.

  Entries are keyed by extension id and checked against a hash of the source, so a changed
  script is reloaded wherever it's next used, on every node, without telling anyone.
  """
  use GenServer

  alias Meridian.Extensions.{Extension, Script}

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, nil}
  end

  @doc "The extension's loaded script, loading it if it changed or isn't loaded yet."
  @spec script(Extension.t()) :: {:ok, Script.t()} | {:error, String.t()}
  def script(%Extension{id: id, name: name, source: source}) do
    hash = :erlang.md5(source)

    case :ets.lookup(@table, {:script, id}) do
      [{_key, ^hash, result}] ->
        result

      _ ->
        result = Script.load(source, name)
        :ets.insert(@table, {{:script, id}, hash, result})
        result
    end
  end

  @doc "Records an extension's latest error."
  def put_error(id, error), do: :ets.insert(@table, {{:error, id}, error})

  @doc "The extension's latest error, or nil."
  def error(id) do
    case :ets.lookup(@table, {:error, id}) do
      [{_key, error}] -> error
      [] -> nil
    end
  end

  @doc "Forgets an extension (its script changed, or it was deleted)."
  def delete(id) do
    :ets.delete(@table, {:script, id})
    :ets.delete(@table, {:error, id})
    :ok
  end
end
