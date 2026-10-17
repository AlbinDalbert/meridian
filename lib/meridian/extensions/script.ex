defmodule Meridian.Extensions.Script do
  @moduledoc """
  An extension's Lua script, loaded and ready to call.

  A script returns a table, and that table is the extension:

      local M = {
        description = "Adds the date to the system prompt.",
        settings = { timezone = "Etc/UTC" },   -- defaults; agents override them
      }

      function M.validate(settings)            -- optional: return an error message, or nothing
      end

      function M.before_run(config, ctx)       -- a hook: defining it is subscribing to it
        table.insert(config.system_prompt, "Today is " .. meridian.now(ctx.settings.timezone))
        return config
      end

      M.jobs = {}
      function M.jobs.cleanup(args, ctx)       -- background work, see meridian.jobs.enqueue
      end

      M.tools = {
        roll = {                               -- a tool the model can call
          description = "Rolls a die.",
          parameters = { type = "object", properties = { sides = { type = "integer" } } },
          run = function(args, ctx)            -- returns text or a table (sent as JSON)
            return tostring(math.random(args.sides or 6))
          end,
        },
      }

      return M

  Scripts run in a sandbox (the `lua` library's: no files, no OS, no `require`), and reach
  Meridian only through the `meridian` table (`Meridian.Extensions.Capabilities`). Loading runs
  the script once; every call then starts from that loaded state, so nothing a call changes
  carries over to the next one. Each load and call runs in its own process, with a time limit,
  a memory limit (`:max_heap_words`) and an instruction budget (`:max_instructions`).

  Values cross the boundary as plain data: tables come back as maps, or as lists when their
  keys are 1..n. An empty table comes back as an empty map.
  """

  alias Meridian.Extensions.Capabilities

  @task_supervisor Meridian.Extensions.TaskSupervisor

  # Where the loaded extension table is kept, so hooks can be called by name.
  @global "__extension"

  @hooks ~w(run_start before_run context before_model_request message_end tool_call
            tool_result step_end run_end thread_created thread_deleted)

  # Called for every streamed chunk: too hot for scripts.
  @unsupported_hooks ~w(model_stream_event)

  @type t :: %__MODULE__{
          lua: Lua.t(),
          description: String.t(),
          settings: map(),
          hooks: [String.t()],
          jobs: [String.t()],
          tools: %{String.t() => tool()},
          validate?: boolean()
        }

  @typedoc "A tool's definition: what the model is told about it."
  @type tool :: %{description: String.t(), parameters: map()}

  defstruct [
    :lua,
    description: "",
    settings: %{},
    hooks: [],
    jobs: [],
    tools: %{},
    validate?: false
  ]

  @tool_name ~r/^[a-zA-Z0-9_-]{1,64}$/

  @no_parameters %{"type" => "object", "properties" => %{}}

  @doc "The hooks a script can subscribe to, in lifecycle order."
  def hooks, do: @hooks

  @doc """
  Loads a script: runs it once and checks that what it returns is an extension. Returns an
  error message (with the line, when there is one) otherwise.
  """
  @spec load(String.t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def load(source, name \\ "extension") when is_binary(source) do
    sandboxed(fn -> do_load(source, name) end, config(:load_timeout, :timer.seconds(5)))
  end

  defp do_load(source, name) do
    {results, lua} =
      Capabilities.install(new_lua())
      |> Lua.eval!(source, decode: false, source: name <> ".lua")

    case results do
      [extension | _] -> describe(Lua.set!(lua, [@global], extension))
      [] -> {:error, "the script must end by returning its table, e.g. `return M`"}
    end
  rescue
    e in [Lua.CompilerException, Lua.RuntimeException] -> {:error, message(e)}
  end

  defp new_lua do
    Lua.new(
      max_instructions: config(:max_instructions, 2_000_000),
      max_call_depth: 200,
      max_string_bytes: 4 * 1024 * 1024
    )
  end

  @inspect """
  local m = __extension
  if type(m) ~= "table" then return type(m) end
  local fields, jobs, tools = {}, {}, {}
  for k, v in pairs(m) do
    if type(k) == "string" then fields[k] = type(v) end
  end
  if type(m.jobs) == "table" then
    for k, v in pairs(m.jobs) do
      if type(k) == "string" then jobs[k] = type(v) end
    end
  end
  if type(m.tools) == "table" then
    for k, v in pairs(m.tools) do
      local tool = { key = type(k), name = tostring(k), type = type(v) }
      if type(v) == "table" then
        tool.description = type(v.description)
        tool.parameters = type(v.parameters)
        tool.run = type(v.run)
      end
      table.insert(tools, tool)
    end
  end
  return "table", fields, jobs, tools
  """

  defp describe(lua) do
    case Lua.eval!(lua, @inspect) do
      {["table", fields, jobs, tools], lua} ->
        fields = from_lua(fields)
        jobs = from_lua(jobs)

        with :ok <- check_type(fields, "description", "string"),
             :ok <- check_type(fields, "settings", "table"),
             :ok <- check_type(fields, "validate", "function"),
             :ok <- check_type(fields, "jobs", "table"),
             :ok <- check_type(fields, "tools", "table"),
             :ok <- check_hooks(fields),
             :ok <- check_jobs(jobs),
             {:ok, tools} <- tools(lua, as_list(from_lua(tools))),
             {:ok, settings} <- default_settings(lua) do
          {:ok,
           %__MODULE__{
             lua: lua,
             description: Lua.get!(lua, [@global, "description"]) || "",
             settings: settings,
             hooks: Enum.filter(@hooks, &Map.has_key?(fields, &1)),
             jobs: jobs |> Map.keys() |> Enum.sort(),
             tools: tools,
             validate?: Map.has_key?(fields, "validate")
           }}
        end

      {[type], _lua} ->
        {:error, "the script must return a table (its extension), but it returned a #{type}"}
    end
  end

  defp check_type(fields, field, type) do
    case fields[field] do
      nil -> :ok
      ^type -> :ok
      other -> {:error, "#{field} must be a #{type}, not a #{other}"}
    end
  end

  defp check_hooks(fields) do
    case Enum.find(@unsupported_hooks, &Map.has_key?(fields, &1)) do
      nil ->
        Enum.find_value(@hooks, :ok, fn hook ->
          with :ok <- check_type(fields, hook, "function"), do: nil
        end)

      hook ->
        {:error, "#{hook} isn't available to extensions"}
    end
  end

  defp check_jobs(jobs) do
    Enum.find_value(jobs, :ok, fn
      {_name, "function"} -> nil
      {name, type} -> {:error, "jobs.#{name} must be a function, not a #{type}"}
    end)
  end

  # An empty Lua table decodes as an empty map.
  defp as_list(value) when value == %{}, do: []
  defp as_list(value), do: value

  # `tools` describes each entry of the script's `tools` table (see @inspect).
  defp tools(lua, tools) do
    tools
    |> Enum.sort_by(& &1["name"])
    |> Enum.reduce_while({:ok, %{}}, fn info, {:ok, acc} ->
      case tool(lua, info) do
        {:ok, name, tool} -> {:cont, {:ok, Map.put(acc, name, tool)}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp tool(lua, %{"key" => "string", "name" => name, "type" => "table"} = info) do
    with :ok <- check_tool_name(name),
         :ok <- check_tool_field(info, name, "run", "function"),
         :ok <- check_tool_field(info, name, "description", "string"),
         {:ok, parameters} <- tool_parameters(lua, name, info["parameters"]) do
      description = Lua.get!(lua, [@global, "tools", name, "description"])

      if String.trim(description) == "",
        do: {:error, "tools.#{name}.description can't be empty"},
        else: {:ok, name, %{description: description, parameters: parameters}}
    end
  end

  defp tool(_lua, %{"key" => "string", "name" => name, "type" => type}),
    do: {:error, "tools.#{name} must be a table, not a #{type}"}

  defp tool(_lua, _info),
    do: {:error, "tools must be a table of tool names and their definitions"}

  defp check_tool_name(name) do
    if Regex.match?(@tool_name, name),
      do: :ok,
      else: {:error, "tool names may only have letters, digits, '_' and '-': #{inspect(name)}"}
  end

  defp check_tool_field(info, name, field, type) do
    case info[field] do
      ^type -> :ok
      "nil" -> {:error, "tools.#{name}.#{field} is missing"}
      other -> {:error, "tools.#{name}.#{field} must be a #{type}, not a #{other}"}
    end
  end

  # A JSON Schema object, given as a table or as JSON text.
  defp tool_parameters(_lua, _name, "nil"), do: {:ok, @no_parameters}

  defp tool_parameters(lua, name, "string") do
    case Jason.decode(Lua.get!(lua, [@global, "tools", name, "parameters"])) do
      {:ok, parameters} -> check_parameters(name, parameters)
      {:error, _} -> {:error, "tools.#{name}.parameters isn't valid JSON"}
    end
  end

  defp tool_parameters(lua, name, "table") do
    parameters = lua |> Lua.get!([@global, "tools", name, "parameters"]) |> from_lua()
    check_parameters(name, parameters)
  end

  defp tool_parameters(_lua, name, type),
    do: {:error, "tools.#{name}.parameters must be a table or JSON text, not a #{type}"}

  defp check_parameters(name, parameters) do
    if is_map(parameters) and plain?(parameters) and parameters["type"] == "object",
      do: {:ok, parameters},
      else: {:error, ~s(tools.#{name}.parameters must be a JSON Schema with type "object")}
  end

  defp default_settings(lua) do
    case lua |> Lua.get!([@global, "settings"]) |> from_lua() do
      nil ->
        {:ok, %{}}

      settings when is_map(settings) ->
        if plain?(settings), do: {:ok, settings}, else: bad_settings()

      _list ->
        bad_settings()
    end
  end

  defp bad_settings,
    do: {:error, "settings must be a table of setting names and their default values"}

  @doc """
  Calls the script's function at `path` (e.g. `["before_run"]`, `["jobs", "cleanup"]`) with
  `args` and, last, the context as scripts see it. `call` is what the script's `meridian.*`
  functions know about the call (see `Meridian.Extensions.Capabilities`).

  Returns the values the function returned, or an error message.
  """
  @spec call(t(), [String.t()], [term()], map(), timeout()) ::
          {:ok, [term()]} | {:error, String.t()}
  def call(%__MODULE__{lua: lua}, path, args, %{ctx: ctx} = call, timeout) do
    sandboxed(
      fn ->
        lua = Lua.put_private(lua, :call, call)
        {args, lua} = Lua.encode_list!(lua, args ++ [Meridian.Extensions.Context.to_lua(ctx)])

        case Lua.call_function(lua, [@global | path], args) do
          {:ok, results, lua} -> {:ok, Enum.map(results, &decode(lua, &1))}
          {:error, exception, _lua} -> {:error, message(exception)}
        end
      end,
      timeout
    )
  end

  # Runs `fun` in its own process, so a script can't take down (or bloat) the caller. The
  # process doesn't outlive the caller either (e.g. a cancelled run killing its tool call).
  defp sandboxed(fun, timeout) do
    max_heap = config(:max_heap_words, 8_000_000)
    caller = self()

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        Process.flag(:max_heap_size, %{size: max_heap, kill: true, error_logger: false})
        exit_with(caller)
        fun.()
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, :killed} -> {:error, "used too much memory"}
      {:exit, reason} -> {:error, "crashed: " <> Exception.format_exit(reason)}
      nil -> {:error, "took longer than #{timeout} ms"}
    end
  end

  # Links the calling process to a watcher that ends it when `caller` goes away, and ends
  # itself when the calling process does.
  defp exit_with(caller) do
    process = self()

    spawn_link(fn ->
      caller_ref = Process.monitor(caller)
      process_ref = Process.monitor(process)

      receive do
        {:DOWN, ^caller_ref, :process, _pid, _reason} -> exit(:caller_down)
        {:DOWN, ^process_ref, :process, _pid, _reason} -> :ok
      end
    end)
  end

  @doc "Decodes a Lua value (see the moduledoc for how tables come back)."
  def decode(lua, value), do: lua |> Lua.decode!(value) |> from_lua()

  @doc false
  def from_lua(entries) when is_list(entries) do
    entries = Enum.map(entries, fn {key, value} -> {key, from_lua(value)} end)
    count = length(entries)

    if count > 0 and Enum.all?(entries, fn {key, _} -> key in 1..count//1 end),
      do: entries |> List.keysort(0) |> Enum.map(&elem(&1, 1)),
      else: Map.new(entries)
  end

  def from_lua(value), do: value

  @doc "Whether a decoded value is plain data (what JSON can hold), with no functions in it."
  def plain?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, value} -> is_binary(key) and plain?(value) end)

  def plain?(value) when is_list(value), do: Enum.all?(value, &plain?/1)

  def plain?(value),
    do: is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value)

  @doc "A readable message for an error a script raised."
  def message(%Lua.CompilerException{diagnostics: [_ | _] = diagnostics}) do
    Enum.map_join(diagnostics, "\n", fn error ->
      case error.position do
        %{line: line} -> "line #{line}: #{error.message}"
        _ -> error.message
      end
    end)
  end

  def message(exception), do: exception |> Exception.message() |> String.trim()

  defp config(key, default) do
    :meridian |> Application.get_env(Meridian.Extensions, []) |> Keyword.get(key, default)
  end
end
