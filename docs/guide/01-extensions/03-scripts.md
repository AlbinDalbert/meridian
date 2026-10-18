# The shape of a script

A script builds a table and returns it. That table is the extension. Every field is optional
except that something must be returned.

```lua
local M = {
  -- Shown in extension lists and in the agent form.
  description = "What this extension does, in one line.",

  -- Settings with their defaults. Each agent that turns the extension on can change them.
  settings = { timezone = "Etc/UTC", strict = false },
}

-- Optional: check an agent's settings when the agent is saved.
function M.validate(settings)
end

-- Hooks: define a function with a hook's name to be called at that point of a run.
function M.before_run(config, ctx)
end

-- Tools the model can call.
M.tools = {}

-- Background jobs your hooks and tools can queue.
M.jobs = {}

return M
```

`function M.before_run(config, ctx)` is the same as `M.before_run = function(config, ctx)`.
Use whichever you like.

## Settings

`settings` holds the defaults. In an agent's form, each enabled extension has a settings box
(JSON) that starts out showing those defaults. What the agent sets is merged over them, and
every hook, tool and job sees the result in `ctx.settings`.

```lua
local M = { settings = { timezone = "Etc/UTC" } }

function M.before_run(config, ctx)
  local now = meridian.now(ctx.settings.timezone)
  -- ...
end
```

A Lua table can't hold `nil`: `{ key = nil }` is the same as `{}`. Use `false` or `""` for
"not set".

Settings are frozen when a run starts. Changing them affects the next run, not one that's
already going.

Settings are a good place for API keys, but anyone who can edit the agent can read them.

## `validate(settings)`

Called when an agent with the extension enabled is saved. It gets the merged settings. Return
an error message to refuse them; return nothing to accept.

```lua
function M.validate(settings)
  if type(settings.max_results) ~= "number" or settings.max_results < 1 then
    return "max_results must be a number of at least 1"
  end
end
```

`type(x)` returns `"nil"`, `"boolean"`, `"number"`, `"string"`, `"table"` or `"function"`.

## Code outside functions

Code at the top level of the script runs once, when the script is loaded. Use it for
constants and helper functions. `meridian.*` functions don't work there: they need to know
whose run they're part of, so they only work inside hooks, tools and jobs.

```lua
local MAX = 500                   -- fine

local function shorten(text)      -- fine: a helper
  return text:sub(1, MAX)
end

meridian.now()                    -- error: not inside a hook, tool or job
```

Every call starts from that freshly loaded state. A hook that changes a variable doesn't
change it for the next call, so you can't keep state in variables between calls.
