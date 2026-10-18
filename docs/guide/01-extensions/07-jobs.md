# Jobs

A job is a function that runs in the background. The run doesn't wait for it. Use one for
anything slow that doesn't have to finish before the agent answers.

```lua
M.jobs = {}

function M.jobs.summarize(args, ctx)
  -- args is what you passed to enqueue
end

function M.run_end(run, ctx)
  meridian.jobs.enqueue("summarize", { thread_id = run.thread_id })
end
```

- A job gets the `args` you passed and the `ctx` of the call that queued it (same user,
  agent and settings).
- It runs with the latest saved version of the script.
- It can take up to a minute. If it errors or times out, it's retried, up to 3 attempts in
  total. If the extension is deleted, or the job function is gone, it's dropped.
- `args` must be plain data (strings, numbers, booleans, tables), because it's stored until
  the job runs.

The options (`unique`, `delay`) are explained under
[`meridian.jobs.enqueue`](08-meridian.md#meridianjobsenqueuename-args-opts).
