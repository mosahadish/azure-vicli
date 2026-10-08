-- test-log.lua: unit tests for log.lua's M.summary (pure - see the module's
-- own header comment) and M.record/M.entries (state.lua-backed, but state.lua
-- itself never touches vim either, so this still runs under plain luajit -
-- reached via LUA_PATH the same way editor.lua's tests reach state.lua, see
-- tests/run.sh).
--
-- Usage: luajit test-log.lua <log.lua path>

local path = arg[1]
assert(path, "usage: luajit test-log.lua <log.lua path>")
local M = dofile(path)

local fails = 0
local function check(name, ok, extra)
  print((ok and "ok  " or "FAIL") .. "  " .. name .. (ok and "" or ("  (" .. tostring(extra) .. ")")))
  if not ok then fails = fails + 1 end
end

-- --- M.summary: non-traceback text -----------------------------------------

do
  local s = M.summary("something went wrong\nsome extra detail nobody needs", 80)
  check("summary: non-traceback picks the FIRST non-empty line", s == "something went wrong", s)
end

do
  local s = M.summary("   \n\n  leading blank lines are skipped  \nmore", 80)
  check("summary: leading blank lines are skipped, and the line is trimmed",
    s == "leading blank lines are skipped", s)
end

-- --- M.summary: python tracebacks -------------------------------------------

do
  local tb = table.concat({
    "Traceback (most recent call last):",
    "  File \"azure-cli.py\", line 42, in fetch",
    "    raise AdoHttpError(\"HTTP 400 for https://example/_apis/x\")",
    "AdoHttpError: HTTP 400 for https://example/_apis/x",
  }, "\n")
  local s = M.summary(tb, 80)
  check("summary: traceback picks the LAST non-empty line, not the header",
    s == "HTTP 400 for https://example/_apis/x", s)
end

do
  -- A generic (non-HTTP) exception class keeps its own prefix - only an
  -- Http-flavoured one (AdoHttpError, *HTTPError, ...) gets stripped, since
  -- for anything else the class name IS the useful part of the message.
  local tb = table.concat({
    "Traceback (most recent call last):",
    "  File \"azure-cli.py\", line 10, in main",
    "ValueError: azure-cli.yml is missing a `pat:` for this account",
  }, "\n")
  local s = M.summary(tb, 80)
  check("summary: a non-HTTP exception class keeps its prefix",
    s == "ValueError: azure-cli.yml is missing a `pat:` for this account", s)
end

do
  local tb = table.concat({
    "Traceback (most recent call last):",
    "  File \"azure-cli.py\", line 99, in fetch",
    "urllib.error.HTTPError: HTTP Error 400: Bad Request",
  }, "\n")
  local s = M.summary(tb, 80)
  check("summary: a dotted HTTPError class name is also recognised and stripped",
    s == "HTTP Error 400: Bad Request", s)
end

-- --- M.summary: truncation ----------------------------------------------------

do
  local long = string.rep("x", 200)
  local s = M.summary(long, 40)
  check("summary: truncates to width minus a small margin", #s <= 40, #s)
  -- U+2026 is 3 bytes in UTF-8 - sub(-3) not sub(-1), which would only
  -- grab the codepoint's last byte.
  check("summary: truncated text ends with an ellipsis", s:sub(-3) == "\u{2026}", s)
end

do
  local short = "short and sweet"
  local s = M.summary(short, 80)
  check("summary: short text is returned untouched (no ellipsis)", s == short, s)
end

do
  check("summary: empty/blank text -> empty string", M.summary("", 80) == "")
  check("summary: nil text -> empty string", M.summary(nil, 80) == "")
  check("summary: whitespace-only text -> empty string", M.summary("   \n\n  ", 80) == "")
end

do
  -- No width given falls back to a sane default rather than erroring.
  local s = M.summary("first line\nsecond", nil)
  check("summary: nil width falls back to a default instead of erroring", s == "first line", s)
end

-- --- M.record / M.entries ----------------------------------------------------

do
  M.clear()
  M.record("PR #123", "boom")
  M.record("work item #7", "kaboom")
  local entries = M.entries()
  check("record: entries are kept oldest first", #entries == 2 and entries[1].source == "PR #123"
    and entries[2].source == "work item #7")
  check("record: each entry keeps its full text and a timestamp",
    entries[1].text == "boom" and type(entries[1].ts) == "number")
end

do
  M.clear()
  for i = 1, 210 do
    M.record("source " .. i, "text " .. i)
  end
  local entries = M.entries()
  check("record: only the most recent 200 entries are kept", #entries == 200, #entries)
  check("record: the oldest entries are the ones dropped", entries[1].source == "source 11", entries[1].source)
  check("record: the newest entry is still the last one recorded", entries[#entries].source == "source 210")
end

print(fails == 0 and "test-log: all cases pass" or ("test-log: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
