defmodule Meridian.Extension do
  @moduledoc """
  The behaviour extensions implement: middleware on the run lifecycle, plus whatever state and
  background work the extension needs, switched on per persona.

  An extension is a module listed in `config :meridian, :extensions`. That makes it
  *installed*; it only runs for personas that enable it (`personas.extensions` maps the
  extension's `name/0` to its settings). Use the core only through `Meridian.Extension.API`.

  Every callback except `name/0` is optional; the core only calls hooks an extension
  implements. Each hook receives a `Meridian.Extension.Context` with this extension's settings
  for the persona.

  ## Hooks

  Chained hooks return `{:cont, value}` to pass a (possibly changed) value to the next
  extension. Observer hooks return `:ok`. A handler that crashes, times out, or returns
  something else is logged and skipped, and the run goes on with the value as it was.

    * `run_start/1` - the run started (observer)
    * `before_run/2` - the run's system prompt sections and model params (chained); may return
      `{:halt, reason}` to reject the run, which then fails with code `rejected`
    * `context/2` - the conversation history about to be sent, in the OpenAI chat format,
      without the system prompt (chained)
    * `before_model_request/2` - the final upstream request body (chained)
    * `model_stream_event/2` - each decoded upstream stream chunk (observer; must be fast)
    * `message_end/2` - the content parts of the assistant message about to be saved (chained)
    * `run_end/2` - the finished run, whatever its outcome (observer; must return quickly, so
      queue an Oban job for slow work)
    * `thread_created/2`, `thread_deleted/2` - thread lifecycle (observers); the context has no
      run
  """

  alias Meridian.Extension.Context

  @typedoc "Per-run settings `before_run/2` may change."
  @type run_config :: %{system_prompt: [String.t()], params: map()}

  @doc "The extension's name: its key in `personas.extensions`. Lowercase, stable."
  @callback name() :: String.t()

  @doc "A one-line description for the admin UI."
  @callback description() :: String.t()

  @doc "Default settings (string keys). A persona's settings are merged over these."
  @callback default_settings() :: map()

  @doc "Checks a persona's settings (already merged over the defaults)."
  @callback validate_settings(settings :: map()) :: :ok | {:error, String.t()}

  @doc "Order among extensions: lower runs first (default 0, then installation order)."
  @callback priority() :: integer()

  @callback run_start(Context.t()) :: :ok
  @callback before_run(run_config(), Context.t()) :: {:cont, run_config()} | {:halt, String.t()}
  @callback context(messages :: [map()], Context.t()) :: {:cont, [map()]}
  @callback before_model_request(body :: map(), Context.t()) :: {:cont, map()}
  @callback model_stream_event(chunk :: map(), Context.t()) :: :ok
  @callback message_end(content :: [map()], Context.t()) :: {:cont, [map()]}
  @callback run_end(Meridian.Runs.Run.t(), Context.t()) :: :ok
  @callback thread_created(Meridian.Threads.Thread.t(), Context.t()) :: :ok
  @callback thread_deleted(Meridian.Threads.Thread.t(), Context.t()) :: :ok

  @optional_callbacks description: 0,
                      default_settings: 0,
                      validate_settings: 1,
                      priority: 0,
                      run_start: 1,
                      before_run: 2,
                      context: 2,
                      before_model_request: 2,
                      model_stream_event: 2,
                      message_end: 2,
                      run_end: 2,
                      thread_created: 2,
                      thread_deleted: 2
end
