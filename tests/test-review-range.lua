-- test-review-range.lua: unit tests for review/range.lua's pure
-- helpers - the ones that never touch vim/ctx, so they run directly under
-- plain luajit: M.resolve_selection (visual selection -> {side, start,
-- stop} over a synthetic diff map, including mixed-side and
-- non-commentable cases) and M.post_args (the --post argv it builds).
--
-- Usage: luajit test-review-range.lua <review/range.lua path>

local path = arg[1]
assert(path, "usage: luajit test-review-range.lua <review/range.lua path>")
local M = dofile(path)

local fails = 0
local function check(name, ok)
  print((ok and "ok  " or "FAIL") .. "  " .. name)
  if not ok then fails = fails + 1 end
end

-- --- resolve_selection -------------------------------------------------------

-- A synthetic diff map for one file, the same {side, lineno} shape
-- cache.lua's parse_diff and pr-review.lua's comment_here use:
--   buffer line 1: hunk metadata (no side/lineno at all)
--   buffer lines 2-4: added lines (R, file lines 10-12)
--   buffer line 5: a context line (R, file line 13 - unchanged lines are
--                  only ever mapped on the right, same as pr-review.lua)
--   buffer line 6: a removed line (L, file line 9)
local MAP = {
  [1] = {},
  [2] = { side = "R", lineno = 10, kind = "add" },
  [3] = { side = "R", lineno = 11, kind = "add" },
  [4] = { side = "R", lineno = 12, kind = "add" },
  [5] = { side = "R", lineno = 13, kind = "ctx" },
  [6] = { side = "L", lineno = 9, kind = "del" },
}

do
  local r = M.resolve_selection(MAP, 2, 4)
  check("forward selection: side", r and r.side == "R")
  check("forward selection: start", r and r.start == 10)
  check("forward selection: stop", r and r.stop == 12)
end

do
  -- Selection made bottom-to-top (line(".") < line("v")) - the same result.
  local r = M.resolve_selection(MAP, 4, 2)
  check("reversed selection: side", r and r.side == "R")
  check("reversed selection: start", r and r.start == 10)
  check("reversed selection: stop", r and r.stop == 12)
end

do
  -- A single-line selection: start == stop.
  local r = M.resolve_selection(MAP, 3, 3)
  check("single-line selection collapses", r and r.start == 11 and r.stop == 11)
end

do
  -- Both ends land on the right side even though the selection also
  -- crosses the context line at buffer 5 - only the two ends are checked.
  local r = M.resolve_selection(MAP, 2, 5)
  check("ends-only check ignores what's between them", r and r.side == "R" and r.start == 10 and r.stop == 13)
end

do
  -- Mixed-side: one end added (R), the other removed (L).
  local r, err = M.resolve_selection(MAP, 3, 6)
  check("mixed-side selection rejected", r == nil)
  check("mixed-side selection reason mentions both sides", err and err:match("both sides") ~= nil)
end

do
  -- Non-commentable: one end is the hunk-metadata line (no side/lineno).
  local r, err = M.resolve_selection(MAP, 1, 3)
  check("selection touching metadata line rejected", r == nil)
  check("non-commentable reason names the line", err and err:match("^line 1 ") ~= nil)
end

do
  -- Non-commentable at the far (out-of-range) end too.
  local r, err = M.resolve_selection(MAP, 2, 99)
  check("selection past the end of the map rejected", r == nil)
  check("out-of-range reason names the line", err and err:match("^line 99 ") ~= nil)
end

-- --- post_args ----------------------------------------------------------------

do
  local args = M.post_args("src/foo.cs", "R", 10, 12, "looks off")
  check("range post_args: --post", args[1] == "--post")
  check("range post_args: path", args[2] == "src/foo.cs")
  check("range post_args: side", args[3] == "R")
  check("range post_args: start", args[4] == "10")
  check("range post_args: text", args[5] == "looks off")
  check("range post_args: endLine", args[6] == "12")
  check("range post_args: exactly 6 elements", #args == 6)
end

do
  -- stop == start collapses to the plain 4-argument (path/side/line/text)
  -- --post form comment_here itself builds - 5 array elements once --post
  -- is counted, with no 6th (endLine) element.
  local args = M.post_args("src/foo.cs", "L", 9, 9, "single line")
  check("collapsed post_args: exactly 5 elements", #args == 5)
  check("collapsed post_args: no endLine", args[6] == nil)
end

do
  -- A nil stop (single-line caller that never resolved a range) behaves the
  -- same as stop == start.
  local args = M.post_args("src/foo.cs", "R", 5, nil, "no range")
  check("nil-stop post_args: exactly 5 elements", #args == 5)
end

print(fails == 0 and "test-review-range: all cases pass" or ("test-review-range: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
