defmodule MeridianWeb.ExtensionComponents do
  @moduledoc """
  Pieces of the extension pages shared by the admin console and `/me`: a script's latest
  error, a read-only view of a script, and the reference for writing one.
  """
  use Phoenix.Component

  import MeridianWeb.CoreComponents, only: [format_time: 1]

  @doc "The extension's latest error (see `Meridian.Extensions.last_error/1`), if it has one."
  attr :error, :map, default: nil

  def last_error(assigns) do
    ~H"""
    <section :if={@error} id="extension-error" class="card extension-error">
      <p>
        <strong>Latest error</strong>
        <span class="muted">in {@error.where}, {format_time(@error.at)}</span>
      </p>
      <pre>{@error.message}</pre>
      <p class="hint">Saving the script clears it.</p>
    </section>
    """
  end

  @doc "A script, read-only."
  attr :source, :string, required: true

  def source_view(assigns) do
    ~H"""
    <pre id="extension-source" class="code-view">{@source}</pre>
    """
  end

  @doc "How to write an extension: the script's shape, the hooks, and the `meridian` table."
  def reference(assigns) do
    ~H"""
    <details id="extension-reference" class="reference">
      <summary>Reference</summary>
      <p>
        A script is Lua 5.3, sandboxed: no files, no OS, no <code>require</code>. It returns a
        table, and that table is the extension:
      </p>
      <dl class="details">
        <dt><code>description</code></dt>
        <dd>A one-line description, shown in lists.</dd>
        <dt><code>settings</code></dt>
        <dd>
          Settings and their defaults. Each persona that turns the extension on can change them;
          a hook gets them in <code>ctx.settings</code>. Lua tables can't hold <code>nil</code>,
          so use <code>false</code> or <code>""</code> for "not set".
        </dd>
        <dt><code>validate(settings)</code></dt>
        <dd>Optional. Return an error message to refuse a persona's settings.</dd>
        <dt><code>jobs</code></dt>
        <dd>
          Functions <code>(args, ctx)</code> run in the background, queued with
          <code>meridian.jobs.enqueue</code>.
        </dd>
      </dl>

      <h3>Hooks</h3>
      <p>
        Define a function to subscribe to a hook. Each gets its value (if any) and
        <code>ctx</code>: <code>run_id</code>, <code>thread_id</code>, <code>user_id</code>,
        <code>settings</code>, and <code>persona</code> (<code>id</code>, <code>slug</code>,
        <code>name</code>, <code>model</code>). Hooks that change a value return it; returning
        nothing leaves it as it was. A hook that fails, or takes over 5 seconds, is skipped.
      </p>
      <dl class="details">
        <dt><code>run_start(ctx)</code></dt>
        <dd>A run started.</dd>
        <dt><code>before_run(config, ctx)</code></dt>
        <dd>
          <code>config.system_prompt</code> (a list of sections) and <code>config.params</code>
          (model params). <code>return false, "reason"</code> rejects the run.
        </dd>
        <dt><code>context(messages, ctx)</code></dt>
        <dd>The conversation about to be sent, without the system prompt.</dd>
        <dt><code>before_model_request(body, ctx)</code></dt>
        <dd>The final request body.</dd>
        <dt><code>message_end(content, ctx)</code></dt>
        <dd>
          The reply's content parts (<code>{~s({type = "text", text = ...})}</code>) before it's
          saved.
        </dd>
        <dt><code>run_end(run, ctx)</code></dt>
        <dd>
          The run ended: <code>id</code>, <code>thread_id</code>, <code>status</code>
          (<code>completed</code>, <code>failed</code>, <code>cancelled</code>, ...),
          <code>error</code>. Queue a job for slow work.
        </dd>
        <dt><code>thread_created(thread, ctx)</code>, <code>thread_deleted(thread, ctx)</code></dt>
        <dd><code>id</code>, <code>title</code>, <code>persona_id</code>.</dd>
      </dl>

      <h3>The <code>meridian</code> table</h3>
      <p>
        Only reaches the data of the user the extension runs for. Functions that can fail return
        <code>nil</code> and an error message.
      </p>
      <dl class="details">
        <dt><code>meridian.threads.get(id)</code></dt>
        <dd>A thread: <code>id</code>, <code>title</code>, <code>persona_id</code>, <code>created_at</code>.</dd>
        <dt><code>meridian.threads.messages(id)</code></dt>
        <dd>Its messages, oldest first: <code>id</code>, <code>role</code>, <code>text</code>, <code>created_at</code>.</dd>
        <dt><code>{"meridian.threads.set_title(id, title, {only_if_untitled = true})"}</code></dt>
        <dd>Sets a thread's title.</dd>
        <dt><code>meridian.model.complete(request)</code></dt>
        <dd>
          A chat completion (<code>messages</code>; <code>model</code> defaults to the persona's).
          Returns the reply's text and the whole response.
        </dd>
        <dt><code>meridian.jobs.enqueue(name, args, opts)</code></dt>
        <dd>
          Runs <code>jobs[name](args, ctx)</code> in the background. <code>opts.unique</code>: a
          key, so the same job isn't queued twice; <code>opts.delay</code>: seconds to wait.
        </dd>
        <dt><code>meridian.now(timezone, format)</code></dt>
        <dd>The time in a timezone (default <code>"Etc/UTC"</code>), ISO 8601 or a <code>strftime</code> format.</dd>
        <dt><code>meridian.json.encode(value)</code>, <code>meridian.json.decode(text)</code></dt>
        <dd>JSON.</dd>
        <dt><code>meridian.log(...)</code></dt>
        <dd>Writes to the server log.</dd>
      </dl>
    </details>
    """
  end
end
