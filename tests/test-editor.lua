-- test-editor.lua: unit tests for editor.lua's pure helpers - the ones that
-- never touch vim.api/vim.fn, so they run directly under plain luajit:
-- M.draft_key/M.get_draft/M.set_draft/M.clear_draft (draft keying/storage
-- over a plain table), M.translate_mentions (@Name -> @<guid> at submit
-- time), M.format_title (the window title every call site builds) and
-- M.compute_height (the 3-to-8-line auto-grow rule).
--
-- editor.lua's own module-load line (`require("azure-cli.state")`) needs
-- state.lua reachable via LUA_PATH - see tests/run.sh, which sets it before
-- running this (state.lua itself never touches vim either).
--
-- Usage: luajit test-editor.lua <editor.lua path>

local path = arg[1]
assert(path, "usage: luajit test-editor.lua <editor.lua path>")
local M = dofile(path)

local fails = 0
local function check(name, ok)
  print((ok and "ok  " or "FAIL") .. "  " .. name)
  if not ok then fails = fails + 1 end
end

-- --- draft_key/get_draft/set_draft/clear_draft -----------------------------

do
  local k1 = M.draft_key(123, "line", "src/foo.cs\tR\t42")
  local k2 = M.draft_key(123, "line", "src/foo.cs\tR\t42")
  local k3 = M.draft_key(123, "file", "src/foo.cs")
  local k4 = M.draft_key(456, "line", "src/foo.cs\tR\t42")
  check("draft_key: same target -> same key", k1 == k2)
  check("draft_key: different kind -> different key", k1 ~= k3)
  check("draft_key: different PR -> different key", k1 ~= k4)
end

do
  local store = {}
  local key = M.draft_key(1, "pr", "")
  check("get_draft: nothing stored yet -> nil", M.get_draft(store, key) == nil)
  M.set_draft(store, key, "half-written thought")
  check("set_draft: stores non-blank text", M.get_draft(store, key) == "half-written thought")
  M.set_draft(store, key, "   ")
  check("set_draft: blank text clears the entry instead of storing it", M.get_draft(store, key) == nil)
  M.set_draft(store, key, "again")
  M.clear_draft(store, key)
  check("clear_draft: removes the entry", M.get_draft(store, key) == nil)
end

do
  -- Nil-safe with no store/key (a caller that opted out of drafts).
  check("get_draft: nil store -> nil, no error", M.get_draft(nil, "x") == nil)
  local ok = pcall(M.set_draft, nil, nil, "text")
  check("set_draft: nil store/key -> no error", ok)
end

-- --- translate_mentions -----------------------------------------------------

do
  local mentions = { { name = "Jane Doe", id = "guid-jane" }, { name = "Bob", id = "guid-bob" } }
  local out = M.translate_mentions("thanks @Jane Doe, can @Bob take a look?", mentions)
  check("translate_mentions: both known names translated to @<guid>",
    out == "thanks @<guid-jane>, can @<guid-bob> take a look?")
end

do
  -- Longest name wins first, so a shorter name that's a prefix of a longer
  -- one doesn't shadow it.
  local mentions = { { name = "Doe", id = "guid-doe" }, { name = "Doe, Jane", id = "guid-jane" } }
  local out = M.translate_mentions("cc @Doe, Jane please", mentions)
  check("translate_mentions: longest match wins over a shorter overlapping name",
    out == "cc @<guid-jane> please")
end

do
  -- A name with no id is left as plain text.
  local mentions = { { name = "No Id Here", id = "" } }
  local out = M.translate_mentions("hi @No Id Here", mentions)
  check("translate_mentions: a name with no id is left untranslated", out == "hi @No Id Here")
end

do
  check("translate_mentions: nil mentions is a no-op", M.translate_mentions("@Someone", nil) == "@Someone")
  check("translate_mentions: empty mentions is a no-op", M.translate_mentions("@Someone", {}) == "@Someone")
  check("translate_mentions: nil text passes through", M.translate_mentions(nil, { { name = "A", id = "x" } })  == nil)
end

do
  -- Multiple occurrences of the same name all translate.
  local mentions = { { name = "Ann", id = "g1" } }
  local out = M.translate_mentions("@Ann and @Ann again", mentions)
  check("translate_mentions: repeated mentions all translate", out == "@<g1> and @<g1> again")
end

-- --- format_title ------------------------------------------------------------

check("format_title: single line", M.format_title("line", { path = "src/foo.cs", lineno = 42 })
  == "Comment \u{00B7} src/foo.cs:42")
check("format_title: range", M.format_title("range", { path = "src/foo.cs", lineno = 42, end_lineno = 48 })
  == "Comment \u{00B7} src/foo.cs:42\u{2013}48")
check("format_title: range collapses when end == start",
  M.format_title("range", { path = "src/foo.cs", lineno = 42, end_lineno = 42 })
  == "Comment \u{00B7} src/foo.cs:42")
check("format_title: file", M.format_title("file", { path = "src/foo.cs" }) == "File comment \u{00B7} src/foo.cs")
check("format_title: pr", M.format_title("pr", {}) == "PR comment")
check("format_title: reply names the author", M.format_title("reply", { author = "Jane Doe" }) == "Reply \u{00B7} Jane Doe")
check("format_title: reply falls back when author unknown", M.format_title("reply", {}) == "Reply \u{00B7} ?")
check("format_title: edit", M.format_title("edit", {}) == "Edit comment")
check("format_title: workitem", M.format_title("workitem", { id = 123 }) == "Comment \u{00B7} #123")
check("format_title: unknown kind falls back to a generic title", M.format_title("nonsense", {}) == "Comment")

-- --- compute_height -----------------------------------------------------------

check("compute_height: one line -> the 3-line floor", M.compute_height(1) == 3)
check("compute_height: two lines -> the 3-line floor still", M.compute_height(2) == 3)
check("compute_height: five lines -> grows with content", M.compute_height(5) == 6)
check("compute_height: very long content -> capped at 8", M.compute_height(100) == 8)
check("compute_height: nil (no content yet) -> the 3-line floor", M.compute_height(nil) == 3)

print(fails == 0 and "test-editor: all cases pass" or ("test-editor: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
