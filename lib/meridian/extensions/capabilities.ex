defmodule Meridian.Extensions.Capabilities do
  @moduledoc """
  The `meridian` table scripts get: everything an extension can do outside its own script.
  If an extension needs something that isn't here, add it here.

  Everything is scoped to the user of the call's context: an extension running for a user can
  only reach that user's threads, global extension or not.

  Functions that can fail return `nil` and an error message, Lua style.

    * `meridian.threads.get(id)` - a thread (`id`, `title`, `persona_id`, `created_at`), or nil
    * `meridian.threads.messages(id)` - a thread's messages, oldest first (`id`, `role`,
      `text`, `created_at`), or nil
    * `meridian.threads.set_title(id, title, opts)` - sets a thread's title; with
      `{only_if_untitled = true}` a title that's already set is left alone. Returns true
    * `meridian.model.complete(request)` - a non-streaming chat completions request
      (`messages` required; `model` defaults to the persona's). Returns the reply's text and
      the whole response
    * `meridian.jobs.enqueue(name, args, opts)` - runs `M.jobs[name](args, ctx)` in the
      background, with this call's context. `opts.unique`: a key; while a job with the same
      name and key is pending, another isn't queued. `opts.delay`: seconds to wait first
    * `meridian.now(timezone, format)` - the current time as text (`strftime` format,
      default ISO 8601) in an IANA timezone (default `"Etc/UTC"`)
    * `meridian.json.encode(value)`, `meridian.json.decode(text)`
    * `meridian.log(...)` - writes to the server log
  """
  import Ecto.Query

  require Logger

  alias Meridian.Extensions.{Job, Script}
  alias Meridian.Repo
  alias Meridian.Threads.{Message, Thread}
  alias Meridian.{Threads, Upstream}

  @doc "Adds the `meridian` table to a Lua state."
  @spec install(Lua.t()) :: Lua.t()
  def install(lua) do
    lua
    |> function([:threads, :get], &thread/2)
    |> function([:threads, :messages], &messages/2)
    |> function([:threads, :set_title], &set_title/2)
    |> function([:model, :complete], &complete/2)
    |> function([:jobs, :enqueue], &enqueue/2)
    |> function([:now], &now/2)
    |> function([:json, :encode], &json_encode/2)
    |> function([:json, :decode], &json_decode/2)
    |> function([:log], &log/2)
  end

  # Wraps an Elixir implementation: decodes the arguments, finds out what call it's part of,
  # and encodes what it returns.
  defp function(lua, path, implementation) do
    name = Enum.join(["meridian" | path], ".")

    Lua.set!(lua, [:meridian | path], fn args, lua ->
      call =
        case Lua.get_private(lua, :call) do
          {:ok, call} -> call
          _ -> raise Lua.RuntimeException, "#{name} can only be called from a hook or a job"
        end

      args = Enum.map(args, &Script.decode(lua, &1))
      Lua.encode_list!(lua, implementation.(args, Map.put(call, :name, name)))
    end)
  end

  defp argument_error!(call, message), do: raise(Lua.RuntimeException, "#{call.name}: #{message}")

  ## Threads

  defp thread([id | _], call) do
    case owned_thread(call, id) do
      nil -> [nil]
      thread -> [thread_to_lua(thread)]
    end
  end

  defp thread(_args, call), do: argument_error!(call, "expected a thread id")

  defp messages([id | _], call) do
    case owned_thread(call, id) do
      nil -> [nil]
      thread -> [Enum.map(Threads.list_all_messages(thread), &message_to_lua/1)]
    end
  end

  defp messages(_args, call), do: argument_error!(call, "expected a thread id")

  defp set_title([id, title | rest], call) when is_binary(title) do
    opts = List.first(rest) || %{}
    only_if_untitled = is_map(opts) and opts["only_if_untitled"] == true

    with %Thread{} <- owned_thread(call, id),
         :ok <-
           Threads.set_title(id, title |> String.trim() |> String.slice(0, 500),
             only_if_untitled: only_if_untitled
           ) do
      [true]
    else
      nil -> [nil, "not_found"]
      {:error, reason} -> [nil, Atom.to_string(reason)]
    end
  end

  defp set_title(_args, call), do: argument_error!(call, "expected a thread id and a title")

  defp owned_thread(%{ctx: %{user_id: user_id}}, id) when is_binary(id) and is_binary(user_id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one(from t in Thread, where: t.id == ^id and t.user_id == ^user_id)
      :error -> nil
    end
  end

  defp owned_thread(_call, _id), do: nil

  defp thread_to_lua(%Thread{} = thread) do
    %{
      "id" => thread.id,
      "title" => thread.title,
      "persona_id" => thread.persona_id,
      "created_at" => DateTime.to_iso8601(thread.inserted_at)
    }
  end

  defp message_to_lua(%Message{} = message) do
    %{
      "id" => message.id,
      "role" => message.role,
      "text" => Message.text(message),
      "created_at" => DateTime.to_iso8601(message.inserted_at)
    }
  end

  ## Models

  defp complete([%{} = request | _], call) do
    request = Map.put_new(request, "model", call.ctx.persona.model)

    with {:ok, response} <- Upstream.complete(request),
         %{"choices" => [%{"message" => %{"content" => text}} | _]} when is_binary(text) <-
           response do
      [text, response]
    else
      {:error, reason} -> [nil, "the model request failed: #{inspect(reason)}"]
      response -> [nil, "the model gave no text", response]
    end
  end

  defp complete(_args, call), do: argument_error!(call, "expected a request table")

  ## Jobs

  defp enqueue([name | rest], call) when is_binary(name) do
    unless name in call.jobs, do: argument_error!(call, "there is no job #{inspect(name)}")

    {args, opts} =
      case rest do
        [args, %{} = opts | _] -> {args, opts}
        [args | _] -> {args, %{}}
        [] -> {nil, %{}}
      end

    {:ok, _job} =
      call.extension_id
      |> Job.new(name, args || %{}, call.ctx, opts["unique"], opts["delay"])
      |> Oban.insert()

    [true]
  end

  defp enqueue(_args, call), do: argument_error!(call, "expected a job name")

  ## Utilities

  defp now(args, call) do
    timezone = Enum.at(args, 0) || "Etc/UTC"
    format = Enum.at(args, 1)

    with true <- is_binary(timezone),
         {:ok, now} <- DateTime.now(timezone) do
      if is_binary(format),
        do: [Calendar.strftime(now, format)],
        else: [DateTime.to_iso8601(DateTime.truncate(now, :second))]
    else
      _ -> [nil, "unknown timezone #{inspect(timezone)}"]
    end
  rescue
    ArgumentError -> argument_error!(call, "invalid format")
  end

  defp json_encode([value | _], call) do
    case Jason.encode(value) do
      {:ok, json} -> [json]
      {:error, _} -> argument_error!(call, "can't encode this value as JSON")
    end
  end

  defp json_encode([], _call), do: ["null"]

  defp json_decode([text | _], _call) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, value} -> [value]
      {:error, error} -> [nil, Exception.message(error)]
    end
  end

  defp json_decode(_args, call), do: argument_error!(call, "expected a string")

  defp log(args, call) do
    Logger.info("[extension #{call.extension}] " <> Enum.map_join(args, " ", &log_text/1))
    []
  end

  defp log_text(text) when is_binary(text), do: text
  defp log_text(value), do: inspect(value)
end
