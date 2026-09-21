-- test-review-followup.lua: unit tests for review/followup.lua's pure
-- helpers - the ones that never touch vim/ctx, so they run directly under
-- plain luajit: M.select_my_threads (picking "my" anchored/unanchored
-- threads out of a synthetic flat thread list), M.parse_hunks (unified=0
-- hunk-header parsing), M.window_overlaps/M.hunk_new_range (the "changed
-- nearby" window check) and M.map_old_to_new (the old-side -> new-side
-- line-mapping rule), M.classify, M.format_row/M.sort_rows and
-- M.build_lines.
--
-- Usage: luajit test-review-followup.lua <review/followup.lua path>

local path = arg[1]
assert(path, "usage: luajit test-review-followup.lua <review/followup.lua path>")
local M = dofile(path)

local fails = 0
local function check(name, ok)
  print((ok and "ok  " or "FAIL") .. "  " .. name)
  if not ok then fails = fails + 1 end
end

-- --- M.first_comment / M.is_mine / M.preview_text ----------------------------

check("first_comment: first entry of comments",
  M.first_comment({ comments = { { content = "a" }, { content = "b" } } }).content == "a")
check("first_comment: nil thread", M.first_comment(nil) == nil)
check("first_comment: no comments", M.first_comment({ comments = {} }) == nil)

check("is_mine: my first comment", M.is_mine({ comments = { { authorId = "me" } } }, "me") == true)
check("is_mine: someone else's first comment",
  M.is_mine({ comments = { { authorId = "other" } } }, "me") == false)
check("is_mine: nil my_id", M.is_mine({ comments = { { authorId = "me" } } }, nil) == false)

check("preview_text: collapses whitespace runs (including newlines)",
  M.preview_text("hello\n\n  world") == "hello world")
check("preview_text: truncates to the limit (default 80)",
  #M.preview_text(string.rep("x", 200)) == 80)
check("preview_text: a custom limit", M.preview_text("hello world", 5) == "hello")

-- --- M.select_my_threads -------------------------------------------------------

do
  local threads = {
    -- Mine, anchored, source side.
    { id = 1, status = "active", path = "a.cs", side = "R", lineno = 10,
      comments = { { authorId = "me", content = "why not use X here?" }, { authorId = "other", content = "ok" } } },
    -- Mine, anchored, target side (a comment on a removed line).
    { id = 2, status = "fixed", path = "b.cs", side = "L", lineno = 5,
      comments = { { authorId = "me", content = "this looked dead" } } },
    -- Someone else's thread - excluded even though I replied in it.
    { id = 3, status = "active", path = "c.cs", side = "R", lineno = 1,
      comments = { { authorId = "other", content = "hi" }, { authorId = "me", content = "reply" } } },
    -- Mine, file-level (no side/lineno) - unanchored.
    { id = 4, status = "active", path = "d.cs",
      comments = { { authorId = "me", content = "whole file needs docs" } } },
    -- Mine, PR-level (no path at all) - unanchored.
    { id = 5, status = "active",
      comments = { { authorId = "me", content = "overall looks good" } } },
  }
  local anchored, unanchored = M.select_my_threads(threads, "me")
  check("select_my_threads: two anchored (threads 1 and 2)", #anchored == 2)
  check("select_my_threads: two unanchored (threads 4 and 5)", #unanchored == 2)
  check("select_my_threads: someone else's thread excluded", threads[3].id ~= anchored[1].thread.id
    and threads[3].id ~= anchored[2].thread.id)

  local by_id = {}
  for _, r in ipairs(anchored) do by_id[r.thread.id] = r end
  check("select_my_threads: anchored row carries path/side/lineno/status",
    by_id[1].path == "a.cs" and by_id[1].side == "R" and by_id[1].lineno == 10 and by_id[1].status == "active")
  check("select_my_threads: replies counted (comments - 1)", by_id[1].replies == 1)
  check("select_my_threads: a thread with only my comment has 0 replies", by_id[2].replies == 0)
  check("select_my_threads: preview is my first comment's text",
    by_id[1].preview == "why not use X here?")

  local ubypath = {}
  for _, r in ipairs(unanchored) do ubypath[r.path or "<pr>"] = r end
  check("select_my_threads: file-level row keeps its path, no side/lineno",
    ubypath["d.cs"].path == "d.cs" and ubypath["d.cs"].side == nil and ubypath["d.cs"].lineno == nil)
  check("select_my_threads: PR-level row has no path at all", ubypath["<pr>"].path == nil)
end

check("select_my_threads: empty input", (function()
  local a, u = M.select_my_threads({}, "me")
  return #a == 0 and #u == 0
end)())

-- --- M.parse_hunks ---------------------------------------------------------------

do
  local hunks = M.parse_hunks({
    "diff --git a/x.cs b/x.cs",
    "index 111..222 100644",
    "--- a/x.cs",
    "+++ b/x.cs",
    "@@ -10,2 +10,4 @@",
    "+added one",
    "+added two",
    "@@ -20 +22,0 @@",
    "-removed a single old line",
    "@@ -30,3 +29,1 @@ some context hint after the @@",
    "-old a",
    "-old b",
    "+new a",
  })
  check("parse_hunks: finds every hunk header", #hunks == 3)
  check("parse_hunks: modify hunk with explicit counts",
    hunks[1].old_start == 10 and hunks[1].old_count == 2 and hunks[1].new_start == 10 and hunks[1].new_count == 4)
  check("parse_hunks: pure-deletion hunk (new count 0)",
    hunks[2].old_start == 20 and hunks[2].old_count == 1 and hunks[2].new_start == 22 and hunks[2].new_count == 0)
  check("parse_hunks: trailing context text after the second @@ doesn't break parsing",
    hunks[3].old_start == 30 and hunks[3].old_count == 3 and hunks[3].new_start == 29 and hunks[3].new_count == 1)
end

do
  local hunks = M.parse_hunks({ "@@ -5 +5 @@" })
  check("parse_hunks: omitted single-line counts default to 1",
    hunks[1].old_start == 5 and hunks[1].old_count == 1 and hunks[1].new_start == 5 and hunks[1].new_count == 1)
end

check("parse_hunks: no hunks in the input", #M.parse_hunks({ "diff --git a/x b/x", "--- a/x", "+++ b/x" }) == 0)
check("parse_hunks: nil input", #M.parse_hunks(nil) == 0)

-- --- M.hunk_new_range / M.window_overlaps -----------------------------------------

check("hunk_new_range: a normal hunk's inclusive new-side range",
  (function() local a, b = M.hunk_new_range({ new_start = 10, new_count = 3 }); return a == 10 and b == 12 end)())
check("hunk_new_range: a pure deletion collapses to a single point at new_start",
  (function() local a, b = M.hunk_new_range({ new_start = 22, new_count = 0 }); return a == 22 and b == 22 end)())

do
  local hunks = { { new_start = 20, new_count = 2 } }  -- touches new lines 20-21
  check("window_overlaps: exactly at the window edge (line - 3)", M.window_overlaps(hunks, 23, 3) == true)
  check("window_overlaps: exactly at the window edge (line + 3)", M.window_overlaps(hunks, 17, 3) == true)
  check("window_overlaps: just outside the window", M.window_overlaps(hunks, 25, 3) == false)
  check("window_overlaps: default window is 3", M.window_overlaps(hunks, 25) == false)
  check("window_overlaps: right on a changed line", M.window_overlaps(hunks, 20, 0) == true)
  check("window_overlaps: no hunks at all", M.window_overlaps({}, 20, 3) == false)
  check("window_overlaps: nil hunks", M.window_overlaps(nil, 20, 3) == false)
end

-- --- M.map_old_to_new --------------------------------------------------------------

do
  -- Two hunks: lines 1-3 (old) become 1-5 (net +2), then a single old line
  -- 10 is replaced 1-for-1 (net 0) - see the same hunks used in
  -- test-review-since.lua-style synthetic fixtures elsewhere in this repo.
  local hunks = { { old_start = 1, old_count = 3, new_start = 1, new_count = 5 },
                  { old_start = 10, old_count = 1, new_start = 12, new_count = 1 } }
  check("map_old_to_new: a line entirely before the first hunk is unshifted", M.map_old_to_new(hunks, -1) == -1)
  check("map_old_to_new: a line between the two hunks shifts by the first hunk's delta",
    M.map_old_to_new(hunks, 5) == 7)
  check("map_old_to_new: a line after both hunks accumulates the first hunk's +2 shift (the second is a 1-for-1 replace, net 0)",
    M.map_old_to_new(hunks, 20) == 22)
  check("map_old_to_new: a line inside a hunk's deleted range returns nil",
    M.map_old_to_new(hunks, 2) == nil)
  check("map_old_to_new: a line exactly on a replaced line returns nil",
    M.map_old_to_new(hunks, 10) == nil)
end

do
  -- A pure insertion (old_count 0): the anchor line itself (right at the
  -- insertion point) isn't shifted; anything after it is.
  local hunks = { { old_start = 5, old_count = 0, new_start = 6, new_count = 2 } }
  check("map_old_to_new: a pure insertion doesn't shift its own anchor line",
    M.map_old_to_new(hunks, 5) == 5)
  check("map_old_to_new: a line after a pure insertion is shifted forward",
    M.map_old_to_new(hunks, 6) == 8)
end

check("map_old_to_new: no hunks at all is the identity", M.map_old_to_new({}, 42) == 42)
check("map_old_to_new: nil hunks is the identity", M.map_old_to_new(nil, 42) == 42)

-- --- M.classify --------------------------------------------------------------------

check("classify: target side ('L') is always n/a regardless of hunks",
  M.classify("L", { { new_start = 1, new_count = 100 } }, 1, 3) == "n/a")
check("classify: source side, no hunks at all -> unchanged",
  M.classify("R", {}, 10, 3) == "unchanged")
check("classify: source side, nil hunks -> unchanged",
  M.classify("R", nil, 10, 3) == "unchanged")
check("classify: source side, a hunk nearby -> changed",
  M.classify("R", { { new_start = 12, new_count = 1 } }, 10, 3) == "changed")
check("classify: source side, a hunk far away -> unchanged",
  M.classify("R", { { new_start = 100, new_count = 1 } }, 10, 3) == "unchanged")

-- --- M.format_row / M.sort_rows -----------------------------------------------------

do
  local row = { classification = "changed", path = "a.cs", lineno = 42, status = "active",
    preview = "why not use X here?", replies = 1 }
  local line = M.format_row(row)
  check("format_row: carries the icon+word, path:line, status, preview and reply count",
    line:find("a.cs:42", 1, true) ~= nil and line:find("[active]", 1, true) ~= nil
    and line:find('"why not use X here?"', 1, true) ~= nil and line:find("(1 reply)", 1, true) ~= nil)
  check("format_row: singular 'reply' for exactly one", line:find("1 reply)", 1, true) ~= nil)
end

check("format_row: plural 'replies' for anything else",
  M.format_row({ classification = "unchanged", path = "a.cs", lineno = 1, status = "active", preview = "x", replies = 0 })
    :find("(0 replies)", 1, true) ~= nil)

check("format_row: a file-level (unanchored) row shows '(file)', not a line number",
  M.format_row({ path = "a.cs", status = "active", preview = "x", replies = 0 }):find("a.cs  (file)", 1, true) ~= nil)

check("format_row: a PR-level (unanchored) row shows '(PR-level)'",
  M.format_row({ status = "active", preview = "x", replies = 0 }):find("(PR-level)", 1, true) ~= nil)

do
  local rows = {
    { classification = "unchanged", path = "b.cs", lineno = 1 },
    { classification = "changed", path = "z.cs", lineno = 5 },
    { classification = "n/a", path = "a.cs", lineno = 1 },
    { classification = "changed", path = "a.cs", lineno = 9 },
    { classification = "changed", path = "a.cs", lineno = 2 },
  }
  local sorted = M.sort_rows(rows)
  check("sort_rows: changed rows come first", sorted[1].classification == "changed"
    and sorted[2].classification == "changed" and sorted[3].classification == "changed")
  check("sort_rows: within 'changed', sorted by path then line",
    sorted[1].path == "a.cs" and sorted[1].lineno == 2
    and sorted[2].path == "a.cs" and sorted[2].lineno == 9
    and sorted[3].path == "z.cs")
  check("sort_rows: unchanged before n/a", sorted[4].classification == "unchanged"
    and sorted[5].classification == "n/a")
  check("sort_rows: doesn't mutate the input list order", rows[1].path == "b.cs")
end

-- --- M.build_lines -------------------------------------------------------------------

do
  local anchored = {
    { classification = "changed", path = "a.cs", lineno = 2, status = "active", preview = "x", replies = 0 },
    { classification = "unchanged", path = "b.cs", lineno = 1, status = "active", preview = "y", replies = 0 },
  }
  local lines, rows_by_line = M.build_lines(4, "2024-03-15T10:00:00Z", anchored, {})
  check("build_lines: summary line has the date, iteration count and changed/total tally",
    lines[1] == "Since 2024-03-15 (4 new iterations): 1 of 2 threads have nearby changes")
  check("build_lines: blank separator after the summary", lines[2] == "")
  check("build_lines: one row per anchored thread, in the given order", #lines == 4)
  check("build_lines: rows_by_line maps buffer lines to the row records",
    rows_by_line[3] == anchored[1] and rows_by_line[4] == anchored[2])
  check("build_lines: no 'Unanchored' section when there is none", lines[4] == M.format_row(anchored[2]))
end

do
  local lines = M.build_lines(1, "2024-03-15T10:00:00Z", {}, {})
  check("build_lines: singular 'new iteration' and 'thread' for count 1",
    lines[1] == "Since 2024-03-15 (1 new iteration): 0 of 0 threads have nearby changes")
end

do
  local unanchored = { { path = "c.cs", status = "active", preview = "z", replies = 2 } }
  local lines = M.build_lines(2, "2024-03-15T10:00:00Z", {}, unanchored)
  check("build_lines: an 'Unanchored' header and row appear when there are unanchored threads",
    lines[3] == "" and lines[4] == "Unanchored (file/PR-level comments):" and lines[5] == M.format_row(unanchored[1]))
end

check("build_lines: an unparseable review_point falls back to '?' for the date",
  M.build_lines(1, nil, {}, {})[1]:find("Since %? ") ~= nil)

print(fails == 0 and "test-review-followup: all cases pass" or ("test-review-followup: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
