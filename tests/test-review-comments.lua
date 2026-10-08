-- test-review-comments.lua: unit tests for review/comments.lua's pure
-- helpers - the ones that never touch vim/ctx, so they run directly under
-- plain luajit: M.build_comment_map (line->comment mapping over a synthetic
-- popup rendering) and M.apply_edit/M.apply_delete (optimistic apply/revert
-- against a synthetic thread table, with a fake run_write that succeeds or
-- fails on command).
--
-- Usage: luajit test-review-comments.lua <review/comments.lua path>

local path = arg[1]
assert(path, "usage: luajit test-review-comments.lua <review/comments.lua path>")
local M = dofile(path)

local fails = 0
local function check(name, ok)
  print((ok and "ok  " or "FAIL") .. "  " .. name)
  if not ok then fails = fails + 1 end
end

-- --- build_comment_map ------------------------------------------------------

do
  local t1 = { id = 1, comments = { { author = "Alice", content = "hi" } } }
  local t2 = { id = 2, comments = {
    { author = "Bob", content = "line one\nline two" },
    { author = "Alice", content = "reply" },
  } }
  local threads = { t1, t2 }
  -- Mirrors threads_to_lines' own layout: blank separator between threads,
  -- a "thread" header, then per comment a "| author:" header + its
  -- (possibly wrapped) content - written here the way pr-review.lua renders
  -- it (box-drawing characters), a synthetic stand-in for a real popup.
  local lines = {
    "\226\148\140\226\148\128 thread [active]",
    "\226\148\130 Alice:",
    "\226\148\130   hi",
    "",
    "\226\148\140\226\148\128 thread [active]",
    "\226\148\130 Bob:",
    "\226\148\130   line one",
    "\226\148\130   line two",
    "\226\148\130 Alice:",
    "\226\148\130   reply",
  }
  local map = M.build_comment_map(lines, threads)
  check("header line 2 -> t1/Alice", map[2] and map[2].thread == t1 and map[2].comment == t1.comments[1])
  check("header line 6 -> t2/Bob", map[6] and map[6].thread == t2 and map[6].comment == t2.comments[1])
  check("header line 9 -> t2/Alice reply", map[9] and map[9].thread == t2 and map[9].comment == t2.comments[2])
  check("content line 3 unmapped", map[3] == nil)
  check("content line 7 unmapped", map[7] == nil)
  check("content line 8 unmapped", map[8] == nil)
  check("blank line 4 unmapped", map[4] == nil)
  check("thread header line 5 unmapped", map[5] == nil)
  check("mapped exactly 3 lines", (function()
    local n = 0
    for _ in pairs(map) do n = n + 1 end
    return n == 3
  end)())
end

-- --- apply_edit --------------------------------------------------------------

do
  local c = { id = 101, content = "old text" }
  local t = { id = 1, comments = { c } }
  local seen_pending_during_write = nil
  local run_write_ok = function(args, on_ok, on_fail)
    check("edit args", args[1] == "--edit-comment" and args[2] == "1" and args[3] == "101" and args[4] == "new text")
    seen_pending_during_write = c.pending
    on_ok()
  end
  local changes = 0
  M.apply_edit(t, c, "new text", run_write_ok, function() changes = changes + 1 end)
  check("optimistic content applied before write returns", seen_pending_during_write == true)
  check("content updated on success", c.content == "new text")
  check("pending cleared on success", c.pending == nil)
  check("on_change called twice (optimistic + success)", changes == 2)
end

do
  local c = { id = 102, content = "keep me" }
  local t = { id = 2, comments = { c } }
  local run_write_fail = function(args, on_ok, on_fail) on_fail("boom") end
  local last_err
  M.apply_edit(t, c, "won't stick", run_write_fail, function(err) last_err = err end)
  check("content reverted on failure", c.content == "keep me")
  check("pending cleared on failure", c.pending == nil)
  check("on_change saw the error", last_err == "boom")
end

-- --- apply_delete --------------------------------------------------------------

do
  -- Deleting one of two comments: the thread stays, bucket untouched.
  local c1 = { id = 1, content = "a" }
  local c2 = { id = 2, content = "b" }
  local t = { id = 5, comments = { c1, c2 } }
  local bucket = { t }
  local run_write_ok = function(args, on_ok, on_fail)
    check("delete args", args[1] == "--delete-comment" and args[2] == "5" and args[3] == "2")
    on_ok()
  end
  M.apply_delete(t, c2, bucket, run_write_ok, function() end)
  check("comment removed, thread kept", #t.comments == 1 and t.comments[1] == c1)
  check("bucket untouched (thread had another comment)", #bucket == 1 and bucket[1] == t)
end

do
  -- Deleting the only comment: the whole thread disappears from its bucket.
  local c = { id = 9, content = "only" }
  local t = { id = 6, comments = { c } }
  local other = { id = 7, comments = { { id = 10, content = "other" } } }
  local bucket = { other, t }
  local run_write_ok = function(args, on_ok, on_fail) on_ok() end
  M.apply_delete(t, c, bucket, run_write_ok, function() end)
  check("comment removed", #t.comments == 0)
  check("thread removed from bucket", #bucket == 1 and bucket[1] == other)
end

do
  -- Failure restores both the comment and (when applicable) its thread, at
  -- their original positions.
  local c = { id = 11, content = "only" }
  local t = { id = 8, comments = { c } }
  local other = { id = 7, comments = { { id = 10, content = "other" } } }
  local bucket = { other, t }
  local run_write_fail = function(args, on_ok, on_fail) on_fail("nope") end
  local last_err
  M.apply_delete(t, c, bucket, run_write_fail, function(err) last_err = err end)
  check("comment restored", #t.comments == 1 and t.comments[1] == c)
  check("thread restored at its original position", #bucket == 2 and bucket[2] == t)
  check("on_change saw the error", last_err == "nope")
end

print(fails == 0 and "test-review-comments: all cases pass" or ("test-review-comments: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
