# Extensions

An extension adds behaviour to your agents: a tool the model can call, a line in the system
prompt, a check that blocks dangerous tool calls, a background job that names your threads.
It's a small Lua script you write and save in the browser. There's no deploy and no restart:
the next run uses the new version.

These pages assume you can program, but not that you know Lua.

- Start below: a first extension, running in a few minutes.
- [Lua in ten minutes](02-lua.md) teaches the Lua you need.
- [The shape of a script](03-scripts.md), [Runs and `ctx`](04-runs.md), [Hooks](05-hooks.md),
  [Tools](06-tools.md) and [Jobs](07-jobs.md) explain every piece.
- [The `meridian` table](08-meridian.md) is the reference for everything a script can reach.
- [Examples](10-examples.md) has complete extensions to copy.

The short reference under the script editor sums up the same things.

## Your first extension

1. Open **Extensions** in `/me` and create a new one. The name is what the model sees in tool
   names, so keep it short: lowercase letters, digits, `_` and `-` (e.g. `dice`).
2. Replace the starting script with this one and save:

   ```lua
   local M = {
     description = "Lets the model roll dice.",
   }

   M.tools = {
     roll = {
       description = "Rolls a die and returns the number.",
       parameters = {
         type = "object",
         properties = {
           sides = { type = "integer", description = "How many sides. Default 6." },
         },
       },
       run = function(args, ctx)
         return tostring(math.random(args.sides or 6))
       end,
     },
   }

   return M
   ```

3. Open **Agents**, edit an agent, tick `dice` under Extensions, and save.
4. Ask that agent "roll a d20 for me". The model sees a tool called `dice__roll`, calls it,
   and answers with the number.

Saving checks the script: it runs it once and makes sure it returns a valid extension. A
syntax error or a missing `return M` is shown in the form, and nothing is saved.

Extensions are off until an agent turns them on. You can make your own (only you can use
them); the operator can make global ones that everyone can turn on.
