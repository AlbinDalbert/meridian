# Runs and `ctx`

A run is one answer from an agent: the user sends a message, and the run lasts until the
agent's reply is finished. The model may call tools along the way, and each model call is a
**step**. Hooks are called at fixed points of a run:

```
run_start
before_run                    once: system prompt, params, tools
│
├─ step 1
│    context                  the conversation about to be sent
│    before_model_request     the final request body
│    (the model replies, streamed to the client)
│    message_end              the finished reply, before it's saved
│    if the model called tools, for each call (all calls run at the same time):
│        tool_call            check or change the call
│        (the tool runs)
│        tool_result          check or change the result
├─ step_end
├─ step 2 ... (only if there were tool calls; at most 10 steps)
│
run_end                       the run is over: completed, failed or cancelled
```

Outside runs, `thread_created` and `thread_deleted` are called when a thread is created
(also by forking) or deleted.

The run **waits for every hook**, so a slow hook makes the agent slow. Work that doesn't
have to finish before the run goes on belongs in a [job](07-jobs.md).

When several enabled extensions use the same hook, they're called in extension name order.
For hooks that change a value, each one gets what the one before it returned.

## `ctx`: who and where

Every hook, tool and job gets `ctx` as its last argument:

| Field | What |
|---|---|
| `ctx.settings` | This extension's settings for this agent (defaults merged with the agent's) |
| `ctx.agent` | `id`, `slug`, `name`, `model` of the agent |
| `ctx.thread_id` | The thread |
| `ctx.run_id` | The run; `nil` in `thread_created` and `thread_deleted` |
| `ctx.user_id` | The user the run is for |

`ctx` also decides what the script can reach: `meridian.*` functions only see the data of
`ctx.user_id`, even in a global extension.
