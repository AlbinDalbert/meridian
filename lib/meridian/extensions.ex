defmodule Meridian.Extensions do
  @moduledoc """
  The installed extensions (see `Meridian.Extension`) and the hook pipeline that calls them.

  An extension is installed by listing it in `config :meridian, :extensions`, and enabled per
  persona: `personas.extensions` maps an extension's name to its settings, which are merged
  over the extension's defaults. Entries for extensions that aren't installed are kept but
  ignored.

  Hook handlers run in a separate process with a timeout (`:hook_timeout`, milliseconds), so a
  handler that crashes or hangs never takes the caller down; it is logged and skipped.
  """
  require Logger

  alias Meridian.Extension.Context
  alias Meridian.Personas.Persona

  @task_supervisor Meridian.Extensions.TaskSupervisor

  @typedoc "An enabled extension with its settings for the persona."
  @type enabled :: {module(), map()}

  @hooks [
    run_start: 1,
    before_run: 2,
    context: 2,
    before_model_request: 2,
    model_stream_event: 2,
    message_end: 2,
    run_end: 2,
    thread_created: 2,
    thread_deleted: 2
  ]

  @haltable [:before_run]

  ## Installed extensions

  @doc "The installed extension modules, in installation order."
  @spec installed() :: [module()]
  def installed do
    :meridian |> Application.get_env(:extensions, []) |> Enum.map(&Code.ensure_loaded!/1)
  end

  @doc "The installed extension called `name`, or nil."
  @spec get(String.t()) :: module() | nil
  def get(name), do: Enum.find(installed(), &(&1.name() == name))

  def description(module), do: optional(module, :description, [], "")
  def default_settings(module), do: optional(module, :default_settings, [], %{})

  @doc """
  Checks a persona's `extensions` map. Returns error messages: every value must be a map, and
  the settings of installed extensions must pass their `validate_settings/1`.
  """
  @spec settings_errors(map()) :: [String.t()]
  def settings_errors(extensions) when is_map(extensions) do
    installed = Map.new(installed(), &{&1.name(), &1})

    Enum.flat_map(extensions, fn
      {name, settings} when is_map(settings) ->
        with {:ok, module} <- Map.fetch(installed, name),
             {:error, message} <-
               optional(module, :validate_settings, [merge_settings(module, settings)], :ok) do
          ["#{name}: #{message}"]
        else
          _ -> []
        end

      {name, _settings} ->
        ["#{name}: settings must be a JSON object"]
    end)
  end

  @doc """
  The installed extensions `persona` enables, with their settings, in the order hooks call
  them (by `priority/0`, then installation order).
  """
  @spec enabled(Persona.t() | nil) :: [enabled()]
  def enabled(%Persona{extensions: extensions}) when is_map(extensions) do
    installed()
    |> Enum.with_index()
    |> Enum.flat_map(fn {module, index} ->
      case Map.fetch(extensions, module.name()) do
        {:ok, settings} when is_map(settings) ->
          [
            {{optional(module, :priority, [], 0), index}, module,
             merge_settings(module, settings)}
          ]

        _ ->
          []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_order, module, settings} -> {module, settings} end)
  end

  def enabled(_persona), do: []

  defp merge_settings(module, settings), do: Map.merge(default_settings(module), settings)

  ## Hooks

  @doc """
  Runs a chained hook: each enabled extension that implements `hook` gets the value the
  previous one returned. Returns `{:cont, value}`, or `{:halt, reason}` if a handler of a hook
  that may halt (`before_run`) halted.

  A handler that fails, or returns something that isn't a valid value for the hook, is
  skipped: the next one gets the value as it was.
  """
  @spec run([enabled()], atom(), term(), Context.t()) :: {:cont, term()} | {:halt, String.t()}
  def run(enabled, hook, value, ctx) do
    Enum.reduce_while(enabled, {:cont, value}, fn {module, settings}, {:cont, value} ->
      case call(module, hook, [value], ctx, settings) do
        {:ok, {:cont, new_value}} ->
          if valid_value?(hook, new_value) do
            {:cont, {:cont, new_value}}
          else
            log_invalid(module, hook, {:cont, new_value})
            {:cont, {:cont, value}}
          end

        {:ok, {:halt, reason}} when hook in @haltable and is_binary(reason) ->
          {:halt, {:halt, reason}}

        {:ok, other} ->
          log_invalid(module, hook, other)
          {:cont, {:cont, value}}

        _skipped ->
          {:cont, {:cont, value}}
      end
    end)
  end

  @doc """
  Calls an observer hook on each enabled extension that implements it, with `args` followed by
  the context. Return values are ignored.
  """
  @spec notify([enabled()], atom(), [term()], Context.t()) :: :ok
  def notify(enabled, hook, args, ctx) do
    Enum.each(enabled, fn {module, settings} -> call(module, hook, args, ctx, settings) end)
  end

  defp call(module, hook, args, %Context{} = ctx, settings) do
    arity = Keyword.fetch!(@hooks, hook)

    if function_exported?(module, hook, arity) do
      args = args ++ [%{ctx | settings: settings}]
      task = Task.Supervisor.async_nolink(@task_supervisor, module, hook, args)

      case Task.yield(task, config(:hook_timeout, :timer.seconds(5))) ||
             Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          {:ok, result}

        {:exit, reason} ->
          Logger.error(
            "Extension #{inspect(module)} crashed in #{hook}: #{Exception.format_exit(reason)}"
          )

          :error

        nil ->
          Logger.error("Extension #{inspect(module)} timed out in #{hook}")
          :error
      end
    else
      :not_implemented
    end
  end

  defp valid_value?(:before_run, %{system_prompt: sections, params: params}),
    do: is_list(sections) and Enum.all?(sections, &is_binary/1) and is_map(params)

  defp valid_value?(:before_run, _value), do: false
  defp valid_value?(hook, value) when hook in [:context, :message_end], do: is_list(value)
  defp valid_value?(:before_model_request, value), do: is_map(value)

  defp log_invalid(module, hook, result) do
    Logger.error(
      "Extension #{inspect(module)} returned an invalid value from #{hook}: " <>
        inspect(result, limit: 5)
    )
  end

  defp optional(module, function, args, default) do
    if function_exported?(module, function, length(args)),
      do: apply(module, function, args),
      else: default
  end

  @doc false
  def config(key, default) do
    :meridian |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
