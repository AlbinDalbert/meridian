# Examples

Complete extensions you can paste into the editor and adapt. Each one loads as is.

## Today's date in the system prompt

```lua
local M = {
  description = "Tells the model today's date and time.",
  settings = { timezone = "Etc/UTC" },
}

function M.validate(settings)
  local _, err = meridian.now(settings.timezone)
  if err then return err end
end

function M.before_run(config, ctx)
  local now = meridian.now(ctx.settings.timezone, "%A %d %B %Y, %H:%M")
  table.insert(config.system_prompt, "It's " .. now .. " (" .. ctx.settings.timezone .. ").")
  return config
end

return M
```

## Name new threads

After the first run of a thread, a background job asks the model for a short title.

```lua
local M = {
  description = "Gives new threads a title.",
  settings = { model = "" },   -- "" means the agent's model
}

M.jobs = {}

function M.jobs.name_thread(args, ctx)
  local messages = meridian.threads.messages(args.thread_id)
  if not messages or #messages == 0 then return end

  local title = assert(meridian.model.complete({
    model = ctx.settings.model ~= "" and ctx.settings.model or nil,
    messages = {
      { role = "system", content = "Reply with a title of at most 6 words for this " ..
        "conversation. No quotes, no punctuation at the end." },
      { role = "user", content = messages[1].text },
    },
    max_tokens = 20,
  }))

  meridian.threads.set_title(args.thread_id, title, { only_if_untitled = true })
end

function M.run_end(run, ctx)
  if run.status ~= "completed" then return end
  local thread = meridian.threads.get(run.thread_id)
  if thread and not thread.title then
    meridian.jobs.enqueue("name_thread", { thread_id = run.thread_id },
      { unique = run.thread_id })
  end
end

return M
```

`ctx.settings.model ~= "" and ctx.settings.model or nil` is Lua's version of a ternary
(`cond ? a : b`): the setting if it isn't empty, otherwise `nil`, which leaves `model` out so
the agent's model is used.

## Read a web page

A tool that fetches a URL and strips the HTML down to text, so more of the page fits in the
model's 20,000 characters.

```lua
local M = {
  description = "Lets the model read web pages.",
  settings = { max_chars = 15000 },
}

-- Crude HTML to text: drop scripts and styles, turn tags into spaces, squeeze whitespace.
local function html_to_text(html)
  local text = html
    :gsub("<script.-</script>", " ")
    :gsub("<style.-</style>", " ")
    :gsub("<!%-%-.-%-%->", " ")
    :gsub("<[^>]+>", " ")
    :gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
    :gsub("&#39;", "'"):gsub("&amp;", "&")
    :gsub("%s+", " ")
  return text
end

M.tools = {
  fetch = {
    description = "Fetches a web page (http or https) and returns its text.",
    parameters = {
      type = "object",
      properties = { url = { type = "string", description = "The page's full URL" } },
      required = { "url" },
    },
    run = function(args, ctx)
      if type(args.url) ~= "string" then return nil, "url is required" end

      local res, err = meridian.http.request({ url = args.url })
      if not res then return nil, err end

      local body = res.body
      local kind = res.headers["content-type"] or ""
      if kind:find("html") then body = html_to_text(body) end

      return "HTTP " .. res.status .. "\n\n" .. body:sub(1, ctx.settings.max_chars)
    end,
  },
}

return M
```

Two Lua details: `.-` in a pattern matches as little as possible (like `.*?` in regular
expressions), and `gsub` returns two values (the text and the number of replacements). The
`local text = ...` line keeps only the first.

## A guardrail for tool calls

A small model checks every tool call against a policy before it runs.

```lua
local M = {
  description = "Asks a model whether each tool call is allowed.",
  settings = {
    model = "",
    policy = "Never send messages or emails on the user's behalf.",
  },
}

function M.tool_call(call, ctx)
  local verdict = assert(meridian.model.complete({
    model = ctx.settings.model ~= "" and ctx.settings.model or nil,
    messages = {
      { role = "system", content = "Policy: " .. ctx.settings.policy ..
        "\nAnswer ALLOW or DENY, then a short reason." },
      { role = "user", content = "Tool: " .. call.name ..
        "\nArguments: " .. meridian.json.encode(call.arguments) },
    },
    max_tokens = 50,
  }))

  if not verdict:upper():find("^%s*ALLOW") then
    return false, verdict
  end
end

return M
```

If the model call fails, `assert` raises an error. Because `tool_call` is fail-closed, the
call is then blocked, which is the safe outcome for a guardrail.

## Keep long threads under the context limit

```lua
local M = {
  description = "Sends only the most recent messages to the model.",
  settings = { keep = 40 },
}

function M.context(messages, ctx)
  local keep = ctx.settings.keep
  if #messages <= keep then return end

  -- Start at a user message, so no tool result is cut off from its call.
  local start = #messages - keep + 1
  while start <= #messages and messages[start].role ~= "user" do
    start = start + 1
  end
  if start > #messages then return end   -- no user message to start at: send everything

  local kept = {}
  for i = start, #messages do table.insert(kept, messages[i]) end
  return kept
end

return M
```
