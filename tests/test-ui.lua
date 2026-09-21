-- test-ui.lua: ui.lua's pure M.winbar/M.layout helpers.
--
-- Usage: luajit test-ui.lua <ui.lua path>

local path = arg[1]
assert(path, "usage: luajit test-ui.lua <ui.lua path>")

-- M.fit needs vim.fn's character helpers; a tiny UTF-8 shim (every
-- codepoint one cell wide, except a few CJK ones treated as two so the
-- double-width path is exercised) stands in for them. M.winbar/M.layout
-- stay pure and never touch this.
local function utf8_chars(s)
  local out = {}
  local i = 1
  while i <= #s do
    local c = s:byte(i)
    local len = c < 0x80 and 1 or c < 0xE0 and 2 or c < 0xF0 and 3 or 4
    out[#out + 1] = s:sub(i, i + len - 1)
    i = i + len
  end
  return out
end
local function cell_width(ch)
  return (#ch == 3 and ch:byte(1) >= 0xE3 and ch:byte(1) <= 0xE9) and 2 or 1
end
vim = {
  fn = {
    strchars = function(s) return #utf8_chars(s) end,
    strcharpart = function(s, start, len)
      local chars = utf8_chars(s)
      local parts = {}
      for i = start + 1, math.min(#chars, start + len) do parts[#parts + 1] = chars[i] end
      return table.concat(parts)
    end,
    strdisplaywidth = function(s)
      local w = 0
      for _, ch in ipairs(utf8_chars(s)) do w = w + cell_width(ch) end
      return w
    end,
  },
}

local M = dofile(path)

local fails = 0
local function check(name, cond)
  if cond then
    print("ok   " .. name)
  else
    fails = fails + 1
    print("FAIL " .. name)
  end
end

-- M.winbar -------------------------------------------------------------

check("winbar: context + tags + help",
  M.winbar({ "PR #123", "feature/x -> main", "14 files" }, { "[active-only]", "[ignore-ws]" })
  == "PR #123 \u{00B7} feature/x -> main \u{00B7} 14 files   [active-only] [ignore-ws]   ?: help")

check("winbar: no tags",
  M.winbar({ "Overview", "PR #123" }, {}) == "Overview \u{00B7} PR #123   ?: help")

check("winbar: no context, only tags",
  M.winbar({}, { "[narrow]" }) == "[narrow]   ?: help")

check("winbar: nothing at all still has help",
  M.winbar({}, {}) == "?: help")

check("winbar: blank context entries are skipped",
  M.winbar({ "x", "", "y" }, {}) == "x \u{00B7} y   ?: help")

check("winbar: blank tag entries are skipped",
  M.winbar({ "x" }, { "", "[a]", "" }) == "x   [a]   ?: help")

-- M.fit -----------------------------------------------------------------

check("fit: pads short text to n cells", M.fit("abc", 6) == "abc   ")
check("fit: exact width is untouched", M.fit("abcdef", 6) == "abcdef")
check("fit: truncates by cells with an ellipsis", M.fit("abcdefgh", 6) == "abcde\u{2026}")
check("fit: never cuts a multi-byte character in half",
  M.fit("caf\u{00E9}s au lait", 6) == "caf\u{00E9}s\u{2026}")
check("fit: double-width characters count as two cells",
  vim.fn.strdisplaywidth(M.fit("\u{65E5}\u{672C}\u{8A9E}\u{6587}", 5)) == 5)
check("fit: zero width is empty", M.fit("abc", 0) == "")
check("fit: nil is padding", M.fit(nil, 3) == "   ")

check("winbar: nil parts/tags default to empty",
  M.winbar(nil, nil) == "?: help")

-- M.layout ---------------------------------------------------------------

-- A wide window: every column reaches its ideal, nothing dropped, and a
-- `grow` column (title) soaks up whatever's left over beyond that.
do
  local columns = {
    { key = "title", min = 20, ideal = 36, weight = 3, grow = true },
    { key = "repo", min = 8, ideal = 14, weight = 1 },
    { key = "author", min = 6, ideal = 10, weight = 1, priority = 3 },
  }
  local r = M.layout(columns, 100)
  check("layout: repo/author reach ideal", r.widths.repo == 14 and r.widths.author == 10)
  check("layout: title grows past its own ideal with the leftover", r.widths.title > 36)
  check("layout: nothing dropped when it all fits", #r.dropped == 0 and r.narrow == false)
  check("layout: widths sum to the available width",
    r.widths.title + r.widths.repo + r.widths.author == 100)
end

-- A tight window: every column stays at min, nothing grows, nothing dropped
-- (the minimums alone already fit).
do
  local columns = {
    { key = "title", min = 20, ideal = 36, weight = 3, grow = true },
    { key = "repo", min = 8, ideal = 14, weight = 1 },
    { key = "author", min = 6, ideal = 10, weight = 1, priority = 3 },
  }
  local r = M.layout(columns, 34)
  check("layout: exact-minimum window keeps every column at min",
    r.widths.title == 20 and r.widths.repo == 8 and r.widths.author == 6)
  check("layout: nothing dropped at exactly the minimum total", #r.dropped == 0)
end

-- Even the minimums don't fit: lowest-priority columns drop first, in
-- priority order, until the rest fit.
do
  local columns = {
    { key = "title", min = 20, ideal = 36, weight = 3, grow = true },
    { key = "repo", min = 8, ideal = 14, weight = 1 },
    { key = "author", min = 6, ideal = 10, weight = 1, priority = 3 },
    { key = "reviewer", min = 0, ideal = 20, weight = 2, grow = true, priority = 1 },
    { key = "updated", min = 8, ideal = 12, weight = 1, priority = 2 },
  }
  local r = M.layout(columns, 30)  -- title(20)+repo(8) = 28 alone fits; author/updated/reviewer must go
  check("layout: narrow flag set once anything is dropped", r.narrow == true)
  check("layout: reviewer summary drops first (lowest priority)", r.dropped[1] == "reviewer")
  check("layout: updated-human drops second", r.dropped[2] == "updated")
  check("layout: title and repo (undroppable) survive", r.widths.title ~= nil and r.widths.repo ~= nil)
  check("layout: dropped columns carry no width", r.widths.reviewer == nil and r.widths.updated == nil)
end

-- Dropping continues until either the minimums fit or nothing more is
-- droppable (undroppable columns are never removed, even if they still
-- don't fit - the caller just gets a window narrower than the minimums ask
-- for, same as any other UI under an impossibly small terminal).
do
  local columns = {
    { key = "title", min = 20, ideal = 36, weight = 3, grow = true },
    { key = "author", min = 6, ideal = 10, weight = 1, priority = 1 },
  }
  local r = M.layout(columns, 5)
  check("layout: author dropped even though title alone still doesn't fit",
    #r.dropped == 1 and r.dropped[1] == "author")
  check("layout: title (undroppable) is never removed", r.widths.title == 20)
end

print(fails == 0 and "ui: all cases pass" or ("ui: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
