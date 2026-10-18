# Tools

Tools are what the model can call. Each entry of `M.tools` is a tool:

```lua
M.tools = {
  search = {
    description = "Searches the notes. Use it before answering questions about the user's notes.",
    parameters = {
      type = "object",
      properties = {
        query = { type = "string", description = "What to look for" },
        limit = { type = "integer", description = "At most this many results" },
      },
      required = { "query" },
    },
    run = function(args, ctx)
      -- ...
      return "results..."
    end,
  },
}
```

- **The name** (`search`) may have letters, digits, `_` and `-`. The model sees
  `<extension>__<tool>`, e.g. `notes__search`.
- **`description`** is what the model reads to decide when to call the tool. It matters more
  than you'd think: say what the tool does and when to use it.
- **`parameters`** is a [JSON Schema](https://json-schema.org/understanding-json-schema/)
  object describing the arguments, written as a Lua table (or as JSON text in a string).
  Leave it out for a tool without arguments. An empty Lua table `{}` becomes a JSON object,
  never a list, so leave out empty lists such as `required = {}`.
- **`run(args, ctx)`** does the work. `args` is the arguments the model sent, as a table.
  Don't trust them: the model may leave out required ones or send the wrong type.

What `run` returns becomes the result the model reads:

| `run` returns | The model gets |
|---|---|
| a string | that text |
| a table | the table as JSON |
| nothing | an empty result |
| `nil, "message"` | `Error: message` |
| (an error is raised, or it takes over 30 s) | `Error: ...` |

Failures don't fail the run: the model gets the error and can try again or explain. Results
over 20,000 characters are cut, with a note saying so.

When the model calls several tools in one step, they run at the same time.

Enabling an extension enables all its tools. To make a tool optional, add a setting and
remove the tool in `before_run`.
