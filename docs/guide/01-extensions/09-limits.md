# Limits and debugging

Every call (a hook, a tool or a job) runs on its own, with limits:

| Limit | Value |
|---|---|
| Time, hooks and tools | 30 s |
| Time, jobs | 1 minute |
| Time, loading (saving) a script | 5 s |
| Instructions | 2 million per call |
| Memory | about 64 MB per call |
| Tool result | 20,000 characters (cut, with a note) |
| Steps per run | 10 model calls |

**Instructions** count loop iterations and function calls: 2 million is a couple of million
steps of your own Lua code, roughly half a second to a second of work. Built-in functions such
as `string.gsub` count as one, however much text they process, so prefer one `gsub` over a
loop that walks a string character by character. A script that runs out fails with
`instruction budget exceeded`.

When something goes wrong:

| What fails | What happens |
|---|---|
| A hook raises an error, times out, or returns the wrong shape | It's skipped: the run goes on as if it wasn't there. The error is shown on the extension's page |
| `tool_call` fails | The tool call is blocked (fail-closed) |
| A tool fails | The model gets `Error: ...` as the result |
| A job fails | It's retried, up to 3 attempts |
| A script doesn't load | Its extension is left out of runs, and the error is shown on its page |

A script never crashes a run.

## Debugging

- **Saving shows load errors**, with the line number: syntax errors, a missing `return M`, a
  tool without a description.
- **The extension's page shows the latest error** from a hook, tool or job, with where it
  happened. It updates live.
- **`meridian.log(...)`** writes to the server log, if you can see it.
- **Return values as debugging.** A tool's result is what the model sees, so a tool that
  returns `meridian.json.encode(something)` shows you that value in the conversation.

Common mistakes:

| Symptom | Cause |
|---|---|
| `attempt to index a nil value` | Reading a field of something that's `nil`, e.g. `args.options.limit` when `options` wasn't sent. Check first: `args.options and args.options.limit` |
| `attempt to concatenate a nil value` | `"x" .. nil`. Use `tostring(value)` or a default: `(value or "")` |
| `... can only be called from a hook or a job` | A `meridian.*` call at the top level of the script. Move it into a function |
| A hook seems to do nothing | It changed the value but didn't `return` it |
| A tool's schema is rejected by the model provider | `required = {}` or another empty list became `{}`. Leave empty lists out |
| A list starts with `nil` | Lists start at 1: `list[0]` is `nil` |
