# The `meridian` table

This is how scripts reach anything outside themselves. Each function only sees the data of
the user in `ctx`. Functions that can fail return `nil` and a message, so check the first
value:

```lua
local thread = meridian.threads.get(ctx.thread_id)
if not thread then return end
```

Calling one without the arguments it needs raises an error instead, since that's a bug in
the script.

Lua's `assert` turns a `nil, "message"` into an error with that message. That's handy when
there's nothing better to do than fail:

```lua
local text = assert(meridian.model.complete({ messages = messages }))
```

## `meridian.threads.get(id)`

A thread of this user: `id`, `title`, `agent_id`, `created_at` (ISO 8601 text). `nil` if it
doesn't exist or isn't theirs.

## `meridian.threads.messages(id)`

The thread's messages, oldest first: `id`, `role` (`"user"`, `"assistant"`, `"tool"`),
`text`, `created_at`. `nil` if there's no such thread.

## `meridian.threads.set_title(id, title, opts)`

Sets a thread's title (cut to 500 characters). With `{ only_if_untitled = true }`, a thread
that already has a title keeps it. Returns `true`, or `nil, "not_found"`.

```lua
meridian.threads.set_title(ctx.thread_id, "Trip to Oslo", { only_if_untitled = true })
```

## `meridian.model.complete(request)`

Asks a model, without streaming, and waits for the answer. `request` is a Chat Completions
request: `messages` is required, `model` defaults to the agent's, and any other field
(`temperature`, `max_tokens`, ...) is passed on. Returns the reply's text and the whole
response, or `nil` and a message.

```lua
local text, err = meridian.model.complete({
  messages = {
    { role = "system", content = "Answer yes or no." },
    { role = "user", content = "Is this message rude? " .. message },
  },
  max_tokens = 3,
})
```

In a hook, the run waits for the answer. That's right for a guardrail that must decide
before the run goes on; for anything else, call it from a job.

## `meridian.http.request(request)`

Makes an HTTP request and returns the whole response.

| Request field | What |
|---|---|
| `url` | Required. `http` or `https` |
| `method` | `"GET"` (the default), `"POST"`, `"PUT"`, `"PATCH"`, `"DELETE"`, `"HEAD"` or `"OPTIONS"` |
| `headers` | A table of header names and values |
| `body` | Text. For JSON, use `meridian.json.encode` |

The response has `status` (a number), `headers` (names in lowercase) and `body` (text).

```lua
local res, err = meridian.http.request({
  method = "POST",
  url = "https://api.example.com/v1/search",
  headers = {
    authorization = "Bearer " .. ctx.settings.api_key,
    ["content-type"] = "application/json",   -- names with "-" need ["..."]
  },
  body = meridian.json.encode({ query = args.query }),
})
if not res then return nil, err end
if res.status ~= 200 then return nil, "the API answered " .. res.status end
local data = meridian.json.decode(res.body)
```

- **HTTP errors are responses.** A 404 or 500 comes back as a normal response; check
  `res.status`. `nil, err` means no response at all: a timeout, an address that isn't
  allowed, a host that doesn't exist.
- **Public addresses only.** Requests to private networks, localhost and cloud metadata
  addresses are refused, because a script must not reach the server's own network.
- **Redirects are followed**, up to 5, each checked the same way. `authorization` and `cookie`
  headers aren't sent on to a different host.
- **Limits.** 15 seconds for the whole request. A body over 2 MB is cut there, and the
  response gets `truncated = true`.

## `meridian.jobs.enqueue(name, args, opts)`

Queues `M.jobs[name](args, ctx)` to run in the background, with this call's `ctx`. Returns
`true`. Raises an error if there's no job with that name.

| Option | What |
|---|---|
| `unique` | A key (text). While a job with the same name and key is waiting or running, another isn't queued. Use it so a job runs once per thread: `{ unique = ctx.thread_id }` |
| `delay` | Seconds to wait before running |

```lua
meridian.jobs.enqueue("name_thread", { thread_id = ctx.thread_id },
  { unique = ctx.thread_id, delay = 5 })
```

## `meridian.now(timezone, format)`

The current time as text, in an [IANA timezone](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones)
(default `"Etc/UTC"`). With no format it's ISO 8601 (`2026-10-18T14:03:00+02:00`); with a
[`strftime` format](https://hexdocs.pm/elixir/Calendar.html#strftime/3) it's that. Returns
`nil, "unknown timezone ..."` for a timezone it doesn't know.

```lua
meridian.now("Europe/Stockholm")                     -- "2026-10-18T14:03:00+02:00"
meridian.now("Europe/Stockholm", "%A %d %B, %H:%M")  -- "Sunday 18 October, 14:03"
```

## `meridian.json.encode(value)` and `meridian.json.decode(text)`

Between Lua tables and JSON text. `decode` returns `nil` and a message for invalid JSON.

```lua
meridian.json.encode({ a = 1, list = { 1, 2 } })   -- '{"a":1,"list":[1,2]}'
local data = meridian.json.decode('{"items": [{"id": 7}]}')
local id = data.items[1].id                          -- 7: lists start at 1
```

A table with keys 1, 2, 3... becomes a JSON list; any other table becomes an object. An empty
table becomes `{}`.

## `meridian.log(...)`

Writes its arguments to the server log, with the extension's name. For debugging; only the
operator sees the log.
