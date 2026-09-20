-- test-worddiff.lua: prdash-cache.lua's M.word_diff, the pairing + token-diff
-- that drives the diff pane's word-level highlights. Pure function, no nvim
-- needed beyond the minimal vim.list_extend M.parse_diff itself uses to turn
-- raw `git diff` hunks into the {lines, map} shape word_diff consumes.
--
-- Usage: luajit test-worddiff.lua <prdash-cache.lua path>
--
-- Each case builds a tiny raw hunk by hand (no scratch repo needed - the
-- pairing rule only cares about the del/add run shape, not real history),
-- runs it through M.parse_diff then M.word_diff, and checks the marks.

vim = { list_extend = function(a, b) for _, v in ipairs(b) do a[#a + 1] = v end return a end }

local M = dofile(arg[1])
assert(arg[1], "usage: luajit test-worddiff.lua <prdash-cache.lua path>")

-- marks_for(raw) -> lines, map, marks; marks indexed by buffer line (map/lines
-- index, same numbering word_diff and decorate_diff both use).
local function marks_for(raw)
  local lines, map = M.parse_diff(raw)
  local marks = M.word_diff(lines, map)
  local by_line = {}
  for _, w in ipairs(marks) do
    assert(not by_line[w.line], "at most one mark per line, got two on line " .. w.line)
    by_line[w.line] = w
  end
  return lines, map, by_line
end

-- 1. Single-token change: only "bar"/"qux" should be marked, with the common
-- "foo " prefix and " baz" suffix left alone.
do
  local lines, _, by_line = marks_for({
    "@@ -1,1 +1,1 @@",
    "-foo bar baz",
    "+foo qux baz",
  })
  local d, a = by_line[1], by_line[2]
  assert(d and d.kind == "del" and a and a.kind == "add", "both sides marked")
  assert(lines[1]:sub(d.s + 1, d.e) == "bar", "del range is 'bar', got " .. lines[1]:sub(d.s + 1, d.e))
  assert(lines[2]:sub(a.s + 1, a.e) == "qux", "add range is 'qux', got " .. lines[2]:sub(a.s + 1, a.e))
end

-- 2. Unequal block sizes: 2 deleted lines, 3 added lines. Only the first two
-- pairs get word marks; the trailing, unpaired add line gets none.
do
  local _, _, by_line = marks_for({
    "@@ -1,2 +1,3 @@",
    "-x = aaa",
    "-y = bbb",
    "+x = AAA",
    "+y = BBB",
    "+z = ccc",
  })
  assert(by_line[1] and by_line[2], "both deleted lines of the paired pairs marked")
  assert(by_line[3] and by_line[4], "both added lines of the paired pairs marked")
  assert(not by_line[5], "unpaired trailing add line left plain, got a mark")
end

-- 3. Whole-line rewrite: nothing shared at either end, so both sides skip
-- word marks entirely (the line-level highlight already says it all).
do
  local _, _, by_line = marks_for({
    "@@ -1,1 +1,1 @@",
    "-abcdef",
    "+xyz123",
  })
  assert(not by_line[1] and not by_line[2], "whole-line rewrite gets no word marks")
end

-- 4. Only whitespace differs: the run of spaces is the whole middle: common
-- word tokens on both sides bracket it out.
do
  local lines, _, by_line = marks_for({
    "@@ -1,1 +1,1 @@",
    "-foo  bar",
    "+foo bar",
  })
  local d, a = by_line[1], by_line[2]
  assert(d and a, "whitespace-only change still gets word marks")
  assert(lines[1]:sub(d.s + 1, d.e) == "  ", "del range is the two spaces, got '" .. lines[1]:sub(d.s + 1, d.e) .. "'")
  assert(lines[2]:sub(a.s + 1, a.e) == " ", "add range is the one space, got '" .. lines[2]:sub(a.s + 1, a.e) .. "'")
end

-- 5. Bonus: a pair where one line is over the 1000-byte cap is skipped
-- entirely, even though it would otherwise have a clear single-token change.
do
  local pad = string.rep("x", 1001)
  local _, _, by_line = marks_for({
    "@@ -1,1 +1,1 @@",
    "-" .. pad .. " bar",
    "+" .. pad .. " qux",
  })
  assert(not by_line[1] and not by_line[2], "over-1000-byte pair skipped")
end

print("word_diff ok: single-token, unequal blocks, whole-line rewrite, whitespace-only and the byte cap all check out")
