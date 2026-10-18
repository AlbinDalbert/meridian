# Hooks

To use a hook, define a function with its name. There are two kinds:

- **Observers** (`run_start`, `step_end`, `run_end`, `thread_created`, `thread_deleted`) are
  told something happened. What they return is ignored.
- **Chained hooks** get a value and may change it. Return the changed value, or return
  nothing to leave it as it was. A hook that returns something of the wrong shape is skipped,
  and the error is shown on the extension's page.

Tables are passed by reference, so the usual pattern is to change the table you got and
return it:

```lua
function M.before_run(config, ctx)
  table.insert(config.system_prompt, "Answer in French.")
  return config
end
```

## `run_start(ctx)`

A run started. Observer.

## `before_run(config, ctx)`

Once per run, before the first model call. It decides what holds for the whole run.

| Field | What | You may |
|---|---|---|
| `config.system_prompt` | A list of strings, joined with blank lines into the system prompt. The agent's own prompt comes first | Add, remove or change sections |
| `config.params` | The agent's model parameters, e.g. `{ temperature = 0.7 }` | Change them |
| `config.tools` | The tools this run offers: each has `name`, `description`, `parameters` | Remove tools, reorder them, or change their descriptions. Not add: a tool needs a script to run it |

To refuse the run, return `false` and a reason. The run fails with error code `rejected`, and
the reason is the message the client gets.

```lua
function M.before_run(config, ctx)
  if ctx.settings.read_only then
    -- keep only the tools whose name doesn't contain "delete"
    local kept = {}
    for _, tool in ipairs(config.tools) do
      if not tool.name:find("delete") then table.insert(kept, tool) end
    end
    config.tools = kept
  end
  return config
end
```

## `context(messages, ctx)`

Before **every** model call. `messages` is the conversation about to be sent, oldest first,
without the system prompt. Each message is a table in the OpenAI chat format:

```lua
{ role = "user", content = "What's the weather?" }
{ role = "assistant", content = "", tool_calls = { {
    id = "call_1", type = "function",
    ["function"] = { name = "weather__now", arguments = '{"city":"Oslo"}' },
} } }
{ role = "tool", tool_call_id = "call_1", content = "12°C, rain" }
{ role = "assistant", content = "It's 12°C and raining in Oslo." }
```

`content` is usually a string. A tool call's `arguments` is JSON text, not a table (use
`meridian.json.decode`). `function` is a reserved word in Lua, so that field is written
`["function"]`: `message.tool_calls[1]["function"].name`.

Return the list to change what the model sees: add context,
drop old messages, rewrite them. This changes only what's sent, never the saved thread.

Because it runs before every step, it also sees the tool calls and results of earlier steps
of the same run.

```lua
-- Keep only the last 20 messages.
function M.context(messages, ctx)
  local n = #messages
  if n <= 20 then return end
  local kept = {}
  for i = n - 19, n do table.insert(kept, messages[i]) end
  return kept
end
```

When cutting history, don't cut between an assistant message with `tool_calls` and its `tool`
results. Most models refuse a `tool` message whose call is missing.

## `before_model_request(body, ctx)`

Before every model call, after `context`. `body` is the whole request: `model`, `messages`
(with the system prompt first), `tools`, `stream`, and the agent's params. Return it changed.
This is the last word on what's sent.

```lua
function M.before_model_request(body, ctx)
  body.max_tokens = 1000
  return body
end
```

## `message_end(content, ctx)`

A reply from the model is finished and about to be saved. `content` is a list of parts:

```lua
{ { type = "reasoning", text = "The user wants..." },   -- only if the model reasons
  { type = "text", text = "Here's the answer." } }
```

Return the list changed to change what's saved. It's also called for replies that call tools
(often with no text part) and for partial replies when a run is cancelled.

The client has already seen the reply stream in by now, so this changes the saved message,
not what the user saw.

## `tool_call(call, ctx)`

Before a tool runs. `call` has `id`, `name` (as the model sees it, e.g. `weather__now`), and
`arguments` (a table). You may:

- return nothing to let it run,
- return `call` with changed `arguments`,
- return `false, "reason"` to block it. The model gets `Error: the call was blocked: reason`
  as the result.

This hook is **fail-closed**: if it errors or times out, the call is blocked. A call that
couldn't be checked doesn't run.

```lua
function M.tool_call(call, ctx)
  if call.name == "files__delete" and not ctx.settings.allow_delete then
    return false, "deleting files is turned off for this agent"
  end
end
```

It's called for every tool, including other extensions' tools and the built-in `load_skill`.

## `tool_result(result, ctx)`

After a tool ran (or failed). `result` has `id`, `name`, `arguments`, `content` (the text the
model will get) and `status` (`"ok"` or `"error"`). Return it with changed `content`; nothing
else can change.

```lua
function M.tool_result(result, ctx)
  result.content = result.content:gsub("%d%d%d%-%d%d%-%d%d%d%d", "[redacted]")
  return result
end
```

## `step_end(step, ctx)`

A model call and its tool calls are done. `step` has `index` (1 for the first step) and
`finish_reason` (`"stop"`, `"tool_calls"`, `"length"`, ...). Observer. A run's last step
only gets `step_end` if the run completed.

## `run_end(run, ctx)`

The run is over. `run` has `id`, `thread_id`, `status` (`"completed"`, `"failed"` or
`"cancelled"`) and `error` (`nil`, or a table with `code` and `message`). Observer.

This is the place to queue follow-up work, like naming the thread or saving memories:

```lua
function M.run_end(run, ctx)
  if run.status == "completed" then
    meridian.jobs.enqueue("summarize", { thread_id = run.thread_id })
  end
end
```

## `thread_created(thread, ctx)` and `thread_deleted(thread, ctx)`

`thread` has `id`, `title`, `tags` and `agent_id`. Observers. These aren't part of a run, so
`ctx.run_id` is `nil`, and `ctx.settings` comes from the agent as it is now.
