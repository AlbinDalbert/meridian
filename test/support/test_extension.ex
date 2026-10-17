defmodule Meridian.TestExtension do
  @moduledoc """
  An extension for testing the hook pipeline, installed in the test environment only.

  It reports every hook call to the test process that enabled it, as
  `{:hook, hook, value, ctx}` (`value` is nil for `run_start`), and behaves according to its
  `mode` setting in the hooks listed in `only` (all hooks if unset):

    * `"observe"` - passes values through unchanged
    * `"modify"` - changes each chained value in a recognisable way
    * `"crash"`, `"slow"` (never returns), `"invalid"` (returns garbage), `"halt"`
  """
  @behaviour Meridian.Extension

  @modes ~w(observe modify crash slow invalid halt)

  @doc "A persona `extensions` map that enables this extension for the calling process."
  def enable(mode \\ "observe", only \\ nil) do
    pid = self() |> :erlang.pid_to_list() |> List.to_string()
    %{"test" => %{"pid" => pid, "mode" => mode, "only" => only}}
  end

  @impl true
  def name, do: "test"

  @impl true
  def description, do: "Reports hook calls to a test."

  @impl true
  def default_settings, do: %{"pid" => nil, "mode" => "observe", "only" => nil}

  @impl true
  def validate_settings(%{"mode" => mode}) when mode in @modes, do: :ok
  def validate_settings(_settings), do: {:error, "unknown mode"}

  @impl true
  def run_start(ctx), do: observe(:run_start, nil, ctx)

  @impl true
  def before_run(config, ctx) do
    chain(:before_run, config, ctx, fn config ->
      %{
        config
        | system_prompt: config.system_prompt ++ ["Test section."],
          params: Map.put(config.params, "seed", 1)
      }
    end)
  end

  @impl true
  def context(messages, ctx) do
    chain(:context, messages, ctx, fn messages ->
      List.insert_at(messages, -2, %{"role" => "user", "content" => "Injected."})
    end)
  end

  @impl true
  def before_model_request(body, ctx),
    do: chain(:before_model_request, body, ctx, &Map.put(&1, "user", "test"))

  @impl true
  def model_stream_event(chunk, ctx), do: observe(:model_stream_event, chunk, ctx)

  @impl true
  def message_end(content, ctx),
    do: chain(:message_end, content, ctx, &(&1 ++ [%{"type" => "text", "text" => " [tested]"}]))

  @impl true
  def run_end(run, ctx), do: observe(:run_end, run, ctx)

  @impl true
  def thread_created(thread, ctx), do: observe(:thread_created, thread, ctx)

  @impl true
  def thread_deleted(thread, ctx), do: observe(:thread_deleted, thread, ctx)

  defp observe(hook, value, ctx) do
    report(hook, value, ctx)

    case mode(hook, ctx) do
      "crash" -> raise "crashed in #{hook}"
      "slow" -> Process.sleep(:infinity)
      "invalid" -> :garbage
      _ -> :ok
    end
  end

  defp chain(hook, value, ctx, modify) do
    report(hook, value, ctx)

    case mode(hook, ctx) do
      "modify" -> {:cont, modify.(value)}
      "crash" -> raise "crashed in #{hook}"
      "slow" -> Process.sleep(:infinity)
      "invalid" -> {:cont, :garbage}
      "halt" -> {:halt, "halted in #{hook}"}
      _ -> {:cont, value}
    end
  end

  defp mode(hook, ctx) do
    only = ctx.settings["only"]
    if is_nil(only) or Atom.to_string(hook) in only, do: ctx.settings["mode"], else: "observe"
  end

  defp report(hook, value, ctx) do
    case ctx.settings["pid"] do
      pid when is_binary(pid) ->
        send(:erlang.list_to_pid(String.to_charlist(pid)), {:hook, hook, value, ctx})

      _ ->
        :ok
    end
  end
end
