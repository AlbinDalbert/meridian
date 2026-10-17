defmodule Meridian.Extensions do
  @moduledoc """
  Extensions, and the hook pipeline that calls them.

  An extension is a row: a name and a Lua script (see `Meridian.Extensions.Script` for what a
  script looks like, and `Meridian.Extensions.Capabilities` for what it can do). Global
  extensions (made in the admin console) can be used by everyone; a user's own extensions
  (made in `/me`) only by that user. Saving checks the script by loading it; the new version is
  used from the next hook call on.

  Agents enable extensions by id: `agents.extensions` maps an extension's id to its
  settings, which are merged over the script's defaults. Entries for extensions that are gone,
  or that the agent's user can't use, are kept but ignored.

  Hook handlers run sandboxed with a timeout (`:hook_timeout`, milliseconds). A handler that
  fails, or returns something that isn't a valid value for its hook, is skipped, and the error
  is kept as the extension's latest error (`last_error/1`).

  Scripts can also have tools (see `tool_set/1` and `run_tool/3`), which run with a longer
  timeout (`:tool_timeout`).

  Every handler call emits a `[:meridian, :extensions, :hook]` telemetry event, with the
  `duration` (native time units) and the `extension_id`, `extension` (name), `hook`, and
  `result` (`:ok` or `:error`). Every tool call emits `[:meridian, :extensions, :tool]`, with
  `tool` instead of `hook`.
  """
  import Ecto.Query

  require Logger

  alias Meridian.Accounts.User
  alias Meridian.Extensions.{Cache, Context, Extension, Script}
  alias Meridian.Agents.Agent
  alias Meridian.Repo
  alias Meridian.Runs.Run
  alias Meridian.Threads.Thread

  @typedoc "An enabled extension: the extension, its loaded script, and the agent's settings."
  @type enabled :: {Extension.t(), Script.t(), map()}

  @typedoc """
  A tool of an enabled extension, as offered in a run: `name` is what the model sees
  (`<extension>__<tool>`), `tool` the name in the script, and `definition` what the request
  says about it (`name`, `description`, `parameters`).
  """
  @type tool :: %{
          name: String.t(),
          tool: String.t(),
          enabled: enabled(),
          definition: map()
        }

  @haltable [:before_run]

  # Upstreams' limit on tool names.
  @max_tool_name 64

  @template """
  -- An extension is the table this script returns: its description, its settings (with
  -- their defaults; each agent that turns it on can change them), and a function for
  -- each hook it wants. See the reference below the editor.
  local M = {
    description = "Says hello in the system prompt.",
    settings = { greeting = "Hello" },
  }

  -- Before each run: change the system prompt (a list of sections) and the model params.
  function M.before_run(config, ctx)
    table.insert(config.system_prompt, ctx.settings.greeting .. ", " .. ctx.agent.name .. "!")
    return config
  end

  return M
  """

  @doc "The script a new extension starts with."
  def template, do: @template

  ## Extensions

  @doc "Every extension, global ones first, with its user."
  def list_extensions do
    Repo.all(
      from e in Extension,
        left_join: u in assoc(e, :user),
        order_by: [asc_nulls_first: e.user_id, asc: u.name, asc: e.name],
        preload: [user: u]
    )
  end

  @doc "The extensions `user` can use: the global ones and their own, by name."
  def list_available(%User{id: user_id}) do
    Repo.all(from e in available(user_id), order_by: [asc: e.name, asc_nulls_first: e.user_id])
  end

  defp available(nil), do: from(e in Extension, where: is_nil(e.user_id))

  defp available(user_id),
    do: from(e in Extension, where: is_nil(e.user_id) or e.user_id == ^user_id)

  def get_extension!(id), do: Extension |> Repo.get!(id) |> Repo.preload(:user)

  @doc "Gets an extension, or nil (also for ids that aren't UUIDs)."
  def get_extension(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(Extension, id)
      :error -> nil
    end
  end

  @doc """
  Gets extension `id` if `user` can use it (it's global or theirs); raises
  `Ecto.NoResultsError` otherwise.
  """
  def get_available_extension!(%User{id: user_id}, id),
    do: Repo.one!(from e in available(user_id), where: e.id == ^id)

  def change_extension(%Extension{} = extension, attrs \\ %{}),
    do: Extension.changeset(extension, attrs)

  @doc "Creates an extension: global with no `owner`, otherwise the owner's own."
  def create_extension(owner, attrs) do
    %Extension{user_id: owner && owner.id}
    |> Extension.changeset(attrs)
    |> validate_script()
    |> Repo.insert()
  end

  def update_extension(%Extension{} = extension, attrs) do
    extension
    |> Extension.changeset(attrs)
    |> validate_script()
    |> Repo.update()
    |> tap(fn result -> with {:ok, extension} <- result, do: Cache.delete(extension.id) end)
  end

  def delete_extension(%Extension{} = extension) do
    with {:ok, extension} <- Repo.delete(extension) do
      Cache.delete(extension.id)
      {:ok, extension}
    end
  end

  # A script is checked by loading it, so a broken one is never saved.
  defp validate_script(changeset) do
    source = Ecto.Changeset.get_field(changeset, :source) || ""
    name = Ecto.Changeset.get_field(changeset, :name) || "extension"

    case changeset.valid? && Script.load(source, name) do
      {:error, message} -> Ecto.Changeset.add_error(changeset, :source, message)
      _ -> changeset
    end
  end

  @doc "The extension's loaded script."
  @spec script(Extension.t()) :: {:ok, Script.t()} | {:error, String.t()}
  def script(%Extension{} = extension), do: Cache.script(extension)

  @doc "The extension's description, from its script."
  def description(%Extension{} = extension) do
    case script(extension) do
      {:ok, script} -> script.description
      {:error, _message} -> ""
    end
  end

  @doc "The extension's tools, from its script: name => `%{description, parameters}`."
  def tools(%Extension{} = extension) do
    case script(extension) do
      {:ok, script} -> script.tools
      {:error, _message} -> %{}
    end
  end

  @doc "The extension's default settings, from its script."
  def default_settings(%Extension{} = extension) do
    case script(extension) do
      {:ok, script} -> script.settings
      {:error, _message} -> %{}
    end
  end

  @doc """
  The extension's latest error on this node since it was last saved, or nil:
  `%{where: hook, message: message, at: datetime}`.
  """
  def last_error(%Extension{id: id}), do: Cache.error(id)

  @doc "Subscribes to an extension's errors: `{:extension_error, id, error}`."
  def subscribe(%Extension{id: id}), do: Phoenix.PubSub.subscribe(Meridian.PubSub, topic(id))

  defp topic(id), do: "extension:" <> id

  defp record_error(%Extension{} = extension, where, message) do
    Logger.error("Extension #{extension.name} (#{extension.id}) failed in #{where}: #{message}")
    error = %{where: where, message: message, at: DateTime.utc_now()}
    Cache.put_error(extension.id, error)

    Phoenix.PubSub.broadcast(
      Meridian.PubSub,
      topic(extension.id),
      {:extension_error, extension.id, error}
    )
  end

  ## Agents

  @doc """
  Checks an agent's `extensions` map for an agent of `user_id`. Returns error messages: every
  value must be a map, and the settings of extensions the user can use must pass their
  script's `validate`.
  """
  @spec settings_errors(map(), Ecto.UUID.t() | nil) :: [String.t()]
  def settings_errors(extensions, user_id) when is_map(extensions) do
    usable = extensions |> Map.keys() |> fetch_usable(user_id) |> Map.new(&{&1.id, &1})

    Enum.flat_map(extensions, fn
      {id, settings} when is_map(settings) ->
        case Map.fetch(usable, id) do
          {:ok, extension} -> validate_settings(extension, settings, user_id)
          :error -> []
        end

      {id, _settings} ->
        name = if extension = usable[id], do: extension.name, else: id
        ["#{name}: settings must be a JSON object"]
    end)
  end

  defp validate_settings(extension, settings, user_id) do
    with {:ok, %{validate?: true} = script} <- script(extension),
         settings = Map.merge(script.settings, settings),
         ctx = %Context{agent: %Agent{user_id: user_id}, user_id: user_id, settings: settings},
         {:ok, result} <-
           Script.call(
             script,
             ["validate"],
             [settings],
             call_info(extension, script, ctx),
             timeout()
           ) do
      case result do
        [message | _] when is_binary(message) -> ["#{extension.name}: #{message}"]
        [nil, message | _] when is_binary(message) -> ["#{extension.name}: #{message}"]
        _valid -> []
      end
    else
      {:error, message} -> ["#{extension.name}: couldn't check the settings: #{message}"]
      _no_validate -> []
    end
  end

  # The extensions with these ids that an agent of `user_id` can use, by name.
  defp fetch_usable(ids, user_id) do
    ids = Enum.filter(ids, &match?({:ok, _}, Ecto.UUID.cast(&1)))
    Repo.all(from e in available(user_id), where: e.id in ^ids, order_by: [e.name, e.id])
  end

  @doc """
  The extensions `agent` enables, with their scripts and settings, in the order hooks call
  them (by name). Extensions whose script doesn't load are left out.
  """
  @spec enabled(Agent.t() | nil) :: [enabled()]
  def enabled(%Agent{extensions: extensions, user_id: user_id})
      when is_map(extensions) and map_size(extensions) > 0 do
    extensions
    |> Map.keys()
    |> fetch_usable(user_id)
    |> Enum.flat_map(fn extension ->
      with %{} = settings <- Map.get(extensions, extension.id),
           {:ok, script} <- script(extension) do
        [{extension, script, Map.merge(script.settings, settings)}]
      else
        {:error, message} ->
          record_error(extension, "loading", message)
          []

        _not_a_map ->
          []
      end
    end)
  end

  def enabled(_agent), do: []

  ## Tools

  @doc """
  The tools of the enabled extensions, under the names the model sees: `<extension>__<tool>`,
  shortened to 64 characters if needed, and unique (two extensions can have the same name: a
  global one and a user's own).
  """
  @spec tool_set([enabled()]) :: [tool()]
  def tool_set(enabled) do
    {tools, _taken} =
      for {extension, script, _settings} = entry <- enabled,
          {tool, definition} <- Enum.sort(script.tools),
          reduce: {[], MapSet.new()} do
        {tools, taken} ->
          name = tool_name(extension, tool, taken)

          tool = %{
            name: name,
            tool: tool,
            enabled: entry,
            definition: %{
              "name" => name,
              "description" => definition.description,
              "parameters" => definition.parameters
            }
          }

          {[tool | tools], MapSet.put(taken, name)}
      end

    Enum.reverse(tools)
  end

  defp tool_name(extension, tool, taken) do
    name = extension.name <> "__" <> tool

    if String.length(name) <= @max_tool_name and not MapSet.member?(taken, name) do
      name
    else
      # Keep it recognisable, and make it unique with a hash of where the tool comes from.
      hash = :crypto.hash(:sha256, extension.id <> tool) |> Base.encode16(case: :lower)
      String.slice(name, 0, @max_tool_name - 9) <> "_" <> binary_part(hash, 0, 8)
    end
  end

  @doc """
  Runs `tool` with `arguments` (a map). Returns the result as text for the model (tables are
  sent as JSON), or an error message: the script raised, timed out, or returned
  `nil, "message"`.
  """
  @spec run_tool(tool(), map(), Context.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run_tool(%{enabled: {extension, script, settings}, tool: tool}, arguments, ctx) do
    ctx = %{ctx | settings: settings}
    started = System.monotonic_time()

    result =
      Script.call(
        script,
        ["tools", tool, "run"],
        [arguments],
        call_info(extension, script, ctx),
        config(:tool_timeout, :timer.seconds(30))
      )

    :telemetry.execute(
      [:meridian, :extensions, :tool],
      %{duration: System.monotonic_time() - started},
      %{
        extension_id: extension.id,
        extension: extension.name,
        tool: tool,
        result: elem(result, 0)
      }
    )

    case result do
      {:ok, [nil, message | _]} when is_binary(message) ->
        {:error, message}

      {:ok, [value | _]} ->
        tool_text(value)

      {:ok, []} ->
        {:ok, ""}

      {:error, message} ->
        record_error(extension, "tools." <> tool, message)
        {:error, message}
    end
  end

  defp tool_text(nil), do: {:ok, ""}
  defp tool_text(text) when is_binary(text), do: {:ok, text}

  defp tool_text(value) do
    if Script.plain?(value),
      do: {:ok, Jason.encode!(value)},
      else: {:error, "the tool returned something that isn't text or plain data"}
  end

  @doc """
  Runs the `tool_call` hook on a call (`id`, `name`, `arguments`). Handlers may rewrite the
  arguments (by returning the call), or block it with `return false, "reason"`. A handler that
  fails or returns something invalid blocks the call too: a tool call that couldn't be checked
  doesn't run.
  """
  @spec tool_call([enabled()], map(), Context.t()) :: {:ok, map()} | {:blocked, String.t()}
  def tool_call(enabled, call, ctx) do
    Enum.reduce_while(enabled, {:ok, call}, fn {extension, _script, _settings} = entry,
                                               {:ok, call} ->
      case call(entry, :tool_call, [call], ctx) do
        :not_implemented ->
          {:cont, {:ok, call}}

        :error ->
          {:halt, {:blocked, "#{extension.name} couldn't check the call"}}

        {:ok, results} ->
          case results do
            r when r in [[], [nil]] ->
              {:cont, {:ok, call}}

            [false, reason | _] when is_binary(reason) ->
              {:halt, {:blocked, reason}}

            [false | _] ->
              {:halt, {:blocked, "blocked by #{extension.name}"}}

            [%{"arguments" => arguments} | _] when is_map(arguments) ->
              if Script.plain?(arguments),
                do: {:cont, {:ok, %{call | "arguments" => arguments}}},
                else: {:halt, invalid_tool_call(extension, results)}

            _ ->
              {:halt, invalid_tool_call(extension, results)}
          end
      end
    end)
  end

  defp invalid_tool_call(extension, results) do
    record_error(
      extension,
      "tool_call",
      "returned an invalid value: #{inspect(results, limit: 5, charlists: :as_lists)}"
    )

    {:blocked, "#{extension.name} couldn't check the call"}
  end

  ## Hooks

  @doc """
  Runs a chained hook: each enabled extension that implements `hook` gets the value the
  previous one returned. Returns `{:cont, value}`, or `{:halt, reason}` if a handler of a hook
  that may halt (`before_run`) halted.

  In Lua, a handler returns the (changed) value, or nothing to leave it as it was. A
  `before_run` handler rejects the run with `return false, "reason"`.
  """
  @spec run([enabled()], atom(), term(), Context.t()) :: {:cont, term()} | {:halt, String.t()}
  def run(enabled, hook, value, ctx) do
    Enum.reduce_while(enabled, {:cont, value}, fn {extension, _script, _settings} = entry,
                                                  {:cont, value} ->
      with {:ok, results} <- call(entry, hook, [to_lua(hook, value)], ctx) do
        case chained_result(hook, results, value) do
          {:cont, value} ->
            {:cont, {:cont, value}}

          {:halt, reason} ->
            {:halt, {:halt, reason}}

          :invalid ->
            record_error(
              extension,
              Atom.to_string(hook),
              "returned an invalid value: #{inspect(results, limit: 5, charlists: :as_lists)}"
            )

            {:cont, {:cont, value}}
        end
      else
        _skipped -> {:cont, {:cont, value}}
      end
    end)
  end

  @doc """
  Calls an observer hook on each enabled extension that implements it, with `args` followed by
  the context. Return values are ignored.
  """
  @spec notify([enabled()], atom(), [term()], Context.t()) :: :ok
  def notify(enabled, hook, args, ctx) do
    args = Enum.map(args, &to_lua(hook, &1))
    Enum.each(enabled, &call(&1, hook, args, ctx))
  end

  defp call({extension, script, settings}, hook, args, ctx) do
    hook = Atom.to_string(hook)

    if hook in script.hooks do
      ctx = %{ctx | settings: settings}
      started = System.monotonic_time()
      result = Script.call(script, [hook], args, call_info(extension, script, ctx), timeout())

      :telemetry.execute(
        [:meridian, :extensions, :hook],
        %{duration: System.monotonic_time() - started},
        %{
          extension_id: extension.id,
          extension: extension.name,
          hook: hook,
          result: elem(result, 0)
        }
      )

      case result do
        {:ok, results} ->
          {:ok, results}

        {:error, message} ->
          record_error(extension, hook, message)
          :error
      end
    else
      :not_implemented
    end
  end

  defp call_info(extension, script, ctx),
    do: %{ctx: ctx, extension_id: extension.id, extension: extension.name, jobs: script.jobs}

  # What scripts get for each hook's value: plain maps with string keys.
  defp to_lua(:before_run, %{system_prompt: sections, params: params} = config),
    do: %{"system_prompt" => sections, "params" => params, "tools" => Map.get(config, :tools, [])}

  defp to_lua(_hook, %Run{} = run) do
    %{
      "id" => run.id,
      "thread_id" => run.thread_id,
      "status" => Atom.to_string(run.status),
      "error" => run.error
    }
  end

  defp to_lua(_hook, %Thread{} = thread),
    do: %{"id" => thread.id, "title" => thread.title, "agent_id" => thread.agent_id}

  defp to_lua(_hook, value), do: value

  defp chained_result(_hook, [], value), do: {:cont, value}
  defp chained_result(_hook, [nil | _], value), do: {:cont, value}

  defp chained_result(hook, [false, reason | _], _value)
       when hook in @haltable and is_binary(reason),
       do: {:halt, reason}

  defp chained_result(hook, [new_value | _], value) do
    case from_lua(hook, new_value, value) do
      {:ok, value} -> {:cont, value}
      :error -> :invalid
    end
  end

  # `value` is what the handler was given, for hooks that may only change part of it.
  defp from_lua(:before_run, %{"system_prompt" => sections, "params" => params} = new, value) do
    sections = as_list(sections)
    params = as_map(params)

    with true <-
           is_list(sections) and Enum.all?(sections, &is_binary/1) and is_map(params) and
             Script.plain?(params),
         {:ok, tools} <- tools_from_lua(Map.get(new, "tools"), Map.get(value, :tools)) do
      config = %{system_prompt: sections, params: params}
      {:ok, if(Map.has_key?(value, :tools), do: Map.put(config, :tools, tools), else: config)}
    else
      _ -> :error
    end
  end

  defp from_lua(:tool_result, %{"content" => content}, value) when is_binary(content),
    do: {:ok, %{value | "content" => content}}

  defp from_lua(hook, new, _value), do: from_lua(hook, new)

  # `before_run` may remove tools, reorder them, and change their descriptions, but not add
  # any: a tool needs a script to run it. Parameters stay as the script declared them (a round
  # trip through Lua would turn empty lists into objects).
  defp tools_from_lua(nil, tools), do: {:ok, tools}
  defp tools_from_lua(_new, nil), do: {:ok, nil}

  defp tools_from_lua(new, tools) do
    known = Map.new(tools, &{&1["name"], &1})
    new = as_list(new)

    if is_list(new) do
      Enum.reduce_while(new, {:ok, []}, fn
        %{"name" => name} = tool, {:ok, acc} when is_map_key(known, name) ->
          case tool_from_lua(tool, known[name]) do
            {:ok, tool} -> {:cont, {:ok, [tool | acc]}}
            :error -> {:halt, :error}
          end

        _tool, _acc ->
          {:halt, :error}
      end)
      |> case do
        {:ok, tools} -> {:ok, tools |> Enum.reverse() |> Enum.uniq_by(& &1["name"])}
        :error -> :error
      end
    else
      :error
    end
  end

  defp tool_from_lua(tool, known) do
    case Map.get(tool, "description", known["description"]) do
      description when is_binary(description) -> {:ok, %{known | "description" => description}}
      _ -> :error
    end
  end

  defp from_lua(hook, messages) when hook in [:context, :message_end] do
    messages = as_list(messages)

    if is_list(messages) and Enum.all?(messages, &is_map/1) and Script.plain?(messages),
      do: {:ok, messages},
      else: :error
  end

  defp from_lua(:before_model_request, body) do
    body = as_map(body)
    if is_map(body) and Script.plain?(body), do: {:ok, body}, else: :error
  end

  defp from_lua(_hook, _value), do: :error

  # An empty Lua table comes back as an empty map; it's an empty list where a list is expected.
  defp as_list(value) when value == %{}, do: []
  defp as_list(value), do: value

  defp as_map([]), do: %{}
  defp as_map(value), do: value

  ## Jobs

  @doc false
  # Runs a job queued with `meridian.jobs.enqueue` (see `Meridian.Extensions.Job`).
  def run_job(id, name, args, %Context{} = ctx) do
    with %Extension{} = extension <- get_extension(id),
         {:ok, script} <- script(extension),
         true <- name in script.jobs do
      call = call_info(extension, script, ctx)

      case Script.call(
             script,
             ["jobs", name],
             [args],
             call,
             config(:job_timeout, :timer.minutes(1))
           ) do
        {:ok, _results} ->
          :ok

        {:error, message} ->
          record_error(extension, "jobs." <> name, message)
          {:error, message}
      end
    else
      nil -> {:cancel, "the extension was deleted"}
      false -> {:cancel, "the extension has no job #{inspect(name)} anymore"}
      {:error, message} -> {:error, message}
    end
  end

  defp timeout, do: config(:hook_timeout, :timer.seconds(5))

  @doc false
  def config(key, default) do
    :meridian |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
