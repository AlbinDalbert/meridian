# Lua in ten minutes

Meridian runs Lua 5.3. These are the parts that trip up people coming from other languages.

## Variables

Always write `local`. Without it, a variable is global to the script.

```lua
local name = "Ada"
local count = 3
count = count + 1      -- no += or ++
```

## Comments and strings

Comments start with `--`. Strings join with `..`, not `+`:

```lua
local greeting = "Hello, " .. name .. "!"   -- "Hello, Ada!"
local line = string.format("%s has %d items", name, count)
local n = "x: " .. tostring(42)             -- numbers need tostring
```

## Comparisons and truth

Not equal is `~=`, not `!=`. `and`, `or`, `not` are words.

Only `nil` and `false` are false. `0` and `""` are true, unlike in JavaScript or Python:

```lua
if "" then
  -- this runs
end
local sides = args.sides or 6   -- the usual way to write a default
```

## Blocks and loops

Blocks end with `end`. No braces and no colons:

```lua
if count > 3 then
  label = "many"
elseif count > 0 then
  label = "some"
else
  label = "none"
end

for i = 1, 10 do          -- 1 to 10, both included
  -- ...
end

while count > 0 do
  count = count - 1
end
```

## Functions and errors

Functions can return several values. Meridian uses this for errors: a function that can
fail returns `nil` and a message.

```lua
local function divide(a, b)
  if b == 0 then return nil, "division by zero" end
  return a / b
end

local result, err = divide(1, 0)
if not result then
  -- err is "division by zero"
end
```

## Tables

Tables are the only data structure. The same `{}` makes lists and maps.

```lua
-- A list. Lists start at 1, not 0.
local colors = { "red", "green", "blue" }
local first = colors[1]           -- "red"
local size = #colors              -- 3: # is the length of a list or string
table.insert(colors, "pink")      -- append
table.insert(colors, 1, "black")  -- insert at the front

-- A map (Lua calls the keys "fields").
local user = { name = "Ada", age = 36 }
user.email = "ada@example.com"    -- add a field
local n = user.name               -- same as user["name"]
user.age = nil                    -- remove a field

-- Nested, like JSON.
local request = { messages = { { role = "user", content = "Hi" } } }
```

To loop over a table, `ipairs` goes through a list in order; `pairs` goes through every
field of a map, in no particular order:

```lua
for i, color in ipairs(colors) do
  -- i is 1, 2, 3...
end

for key, value in pairs(user) do
  -- ...
end
```

## String functions and patterns

Method calls on strings use `:`. `s:upper()` is short for `string.upper(s)`:

```lua
local s = "Hello World"
s:upper()                  -- "HELLO WORLD"
s:sub(1, 5)                -- "Hello" (from 1 to 5, both included)
s:find("World")            -- 7, 11 (where it starts and ends), or nil
s:gsub("World", "Lua")     -- "Hello Lua", 1 (the new text, and how many were replaced)
s:match("(%a+) (%a+)")     -- "Hello", "World"
```

Lua's patterns look like regular expressions but aren't: `%a` is a letter, `%d` a digit,
`%s` whitespace, and `%` escapes special characters (`%.` is a dot). See the
[Lua manual on patterns](https://www.lua.org/manual/5.3/manual.html#6.4.1).

## What's not there

Scripts are sandboxed: no files, no `os.execute`, no `require` (so no
libraries). Everything outside the script goes through [the `meridian` table](08-meridian.md).
